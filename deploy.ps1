#Requires -Version 5.1
<#
.SYNOPSIS
    Builds and deploys TelegramRelay to a Linux server.
.DESCRIPTION
    Publishes the .NET relay server and deploys it over SSH using Posh-SSH.
    Frees port 80 by removing the old trading-journal nginx site, then
    installs the relay behind nginx on port 80.
    Requires the Posh-SSH module (auto-installed from PSGallery if missing).
.PARAMETER SkipBuild
    Skip the dotnet publish step (reuse existing server\publish\ artifacts).
.EXAMPLE
    .\deploy.ps1
    .\deploy.ps1 -SkipBuild
#>
param(
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Configuration ──────────────────────────────────────────────────────────────
$SERVER_IP       = "178.104.242.7"
$SERVER_USER     = "root"
$SERVER_PASSWORD = "Asus7720"

$ServiceName   = "telegram-relay"
$DeployDir     = "/opt/telegram-relay"
$AppBinaryName = "TelegramRelay"
$AppPort       = 9090
$PublicPort    = 80            # nginx listens here (443 is xray/v2ray)
$WsPort        = 25345         # cTrader cloud only allows WebSocket on this port
# ──────────────────────────────────────────────────────────────────────────────

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Join-Path $ScriptDir "server\TelegramRelay"
$PublishDir = Join-Path $ScriptDir "server\publish"

# ── Output helpers ─────────────────────────────────────────────────────────────
function Write-Step  ($msg) { Write-Host "  > $msg" -ForegroundColor Cyan   }
function Write-Ok    ($msg) { Write-Host "  v $msg" -ForegroundColor Green  }
function Write-Warn  ($msg) { Write-Host "  ! $msg" -ForegroundColor Yellow }
function Write-Fatal ($msg) { Write-Host "  x $msg" -ForegroundColor Red; exit 1 }

# ── SSH session ────────────────────────────────────────────────────────────────
$Script:Session    = $null
$Script:Credential = $null

function Connect-Server {
    Write-Step "Connecting to ${SERVER_USER}@${SERVER_IP}..."
    $secure            = ConvertTo-SecureString $SERVER_PASSWORD -AsPlainText -Force
    $Script:Credential = [PSCredential]::new($SERVER_USER, $secure)
    $Script:Session    = New-SSHSession -ComputerName $SERVER_IP `
                             -Credential $Script:Credential -AcceptKey -Force
    if (-not $Script:Session.Connected) { Write-Fatal "SSH connection failed" }
    Write-Ok "Connected"
}

function Invoke-Remote {
    param([string]$Command, [switch]$AllowFail)
    $result = Invoke-SSHCommand -SessionId $Script:Session.SessionId -Command $Command
    if (-not $AllowFail -and $result.ExitStatus -ne 0) {
        if ($result.Error) { Write-Host "    $($result.Error)" -ForegroundColor Red }
        Write-Fatal "Remote command failed (exit $($result.ExitStatus)): $Command"
    }
    return $result.Output
}

function Test-Remote ([string]$Command) {
    $result = Invoke-SSHCommand -SessionId $Script:Session.SessionId -Command $Command
    return $result.ExitStatus -eq 0
}

function Send-File ([string]$LocalPath, [string]$RemotePath) {
    Set-SCPItem -ComputerName $SERVER_IP -Credential $Script:Credential `
        -Path $LocalPath -Destination $RemotePath -AcceptKey -Force
}

# ── 1. Local prerequisites ─────────────────────────────────────────────────────
function Assert-LocalTools {
    Write-Step "Checking local tools..."

    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        Write-Fatal "dotnet CLI not found"
    }

    if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
        Write-Step "Installing Posh-SSH module (one-time)..."
        Install-Module -Name Posh-SSH -Force -Scope CurrentUser -Repository PSGallery
    }
    Import-Module Posh-SSH -Force

    Write-Ok "dotnet $(dotnet --version)"
}

# ── 2. Publish .NET app ────────────────────────────────────────────────────────
function Publish-App {
    if ($SkipBuild) {
        Write-Warn "Skipping build (-SkipBuild)"
        if (-not (Test-Path $PublishDir)) { Write-Fatal "No cached publish found. Run without -SkipBuild first." }
        return
    }

    Write-Step "Publishing TelegramRelay (linux-x64, self-contained)..."
    if (Test-Path $PublishDir) { Remove-Item $PublishDir -Recurse -Force }

    & dotnet publish $ProjectDir `
        -c Release `
        -r linux-x64 `
        --self-contained true `
        -o $PublishDir `
        --nologo -v minimal

    if ($LASTEXITCODE -ne 0) { Write-Fatal "dotnet publish failed" }
    Write-Ok "Published to server\publish\"
}

# ── 3. Server requirements ─────────────────────────────────────────────────────
function Assert-ServerRequirements {
    Write-Step "Checking server requirements..."

    $os = (Invoke-Remote "grep PRETTY_NAME /etc/os-release" -AllowFail) -join ""
    Write-Ok "OS: $os"

    # nginx
    if (-not (Test-Remote "command -v nginx")) {
        Write-Step "Installing nginx..."
        Invoke-Remote "apt-get update -qq && apt-get install -y nginx" | Out-Null
        Invoke-Remote "systemctl enable --now nginx"
        Write-Ok "nginx installed"
    } else { Write-Ok "nginx already installed" }

    # rsync
    if (-not (Test-Remote "command -v rsync")) {
        Write-Step "Installing rsync..."
        Invoke-Remote "apt-get install -y rsync" | Out-Null
        Write-Ok "rsync installed"
    } else { Write-Ok "rsync already installed" }

    # firewall
    if (Test-Remote "command -v ufw") {
        Invoke-Remote "ufw allow $WsPort/tcp" | Out-Null
        Write-Ok "ufw: port $WsPort open"
    }

    Write-Step "Creating deploy directory..."
    Invoke-Remote "mkdir -p $DeployDir"
    Write-Ok "$DeployDir ready"
}

# ── 4. Upload files ────────────────────────────────────────────────────────────
function Deploy-Files {
    Write-Step "Uploading app files..."

    $tarPath = Join-Path $ScriptDir "server\publish.tar.gz"
    $publishLeaf = [IO.Path]::GetFileName($PublishDir)
    & tar -czf $tarPath -C ([IO.Path]::GetDirectoryName($PublishDir)) $publishLeaf
    if ($LASTEXITCODE -ne 0) { Write-Fatal "Failed to create archive" }

    Send-File $tarPath "/tmp/"
    Remove-Item $tarPath

    Invoke-Remote "tar -xzf /tmp/publish.tar.gz -C /tmp && rm /tmp/publish.tar.gz"
    Invoke-Remote "rsync -a --delete /tmp/$publishLeaf/ $DeployDir/ && rm -rf /tmp/$publishLeaf"
    Invoke-Remote "chmod +x $DeployDir/$AppBinaryName"

    Write-Ok "Files deployed to $DeployDir"
}

# ── 6. systemd service ─────────────────────────────────────────────────────────
function Install-Service {
    Write-Step "Writing systemd service..."

    $content = @"
[Unit]
Description=Telegram Relay Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$DeployDir
ExecStart=$DeployDir/$AppBinaryName
Restart=always
RestartSec=5
KillSignal=SIGINT
SyslogIdentifier=$ServiceName
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=DOTNET_PRINT_TELEMETRY_MESSAGE=false

[Install]
WantedBy=multi-user.target
"@
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "$ServiceName.service"
    [IO.File]::WriteAllText($tmp, $content, [Text.UTF8Encoding]::new($false))
    Send-File $tmp "/tmp/"
    Remove-Item $tmp

    Invoke-Remote "mv /tmp/$ServiceName.service /etc/systemd/system/$ServiceName.service"
    Invoke-Remote "systemctl daemon-reload && systemctl enable $ServiceName"
    Write-Ok "systemd service registered"

    Write-Step "Stopping old service..."
    Invoke-Remote "systemctl stop $ServiceName" -AllowFail | Out-Null
    Write-Ok "Stopped"

    Write-Step "Starting service..."
    Invoke-Remote "systemctl start $ServiceName"

    # Poll up to 30s
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
    $active   = "unknown"
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        Start-Sleep 2
        $active = (Invoke-Remote "systemctl is-active $ServiceName" -AllowFail) -join ""
        if ($active -like "*active*") { break }
        if ($active -like "*failed*")  { break }
    }

    if ($active -like "*active*") {
        Write-Ok "Service is running"
    } else {
        Write-Warn "Service logs:"
        Invoke-Remote "journalctl -u $ServiceName -n 30 --no-pager" -AllowFail | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
        Write-Fatal "Service failed to start. Fix the error above, then re-run with -SkipBuild."
    }
}

# ── 7. nginx on port 80 ────────────────────────────────────────────────────────
function Install-NginxConfig {
    Write-Step "Writing nginx config (port $PublicPort -> $AppPort)..."

    $conf = "/etc/nginx/sites-available/$ServiceName"

    $content = @"
server {
    listen $PublicPort;
    server_name $SERVER_IP;

    location / {
        proxy_pass         http://localhost:$AppPort;
        proxy_http_version 1.1;
        proxy_set_header   Host              `$host;
        proxy_set_header   X-Real-IP         `$remote_addr;
        proxy_set_header   X-Forwarded-For   `$proxy_add_x_forwarded_for;
        proxy_read_timeout 30s;
    }
}

server {
    listen $WsPort;
    server_name $SERVER_IP;

    location /ws {
        proxy_pass          http://localhost:$AppPort;
        proxy_http_version  1.1;
        proxy_set_header    Upgrade           `$http_upgrade;
        proxy_set_header    Connection        "upgrade";
        proxy_set_header    Host              `$host;
        proxy_set_header    X-Real-IP         `$remote_addr;
        proxy_read_timeout  3600s;
    }
}
"@
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "$ServiceName.nginx"
    [IO.File]::WriteAllText($tmp, $content, [Text.UTF8Encoding]::new($false))
    Send-File $tmp "/tmp/"
    Remove-Item $tmp

    Invoke-Remote "mv /tmp/$ServiceName.nginx $conf"
    Invoke-Remote "ln -sf $conf /etc/nginx/sites-enabled/$ServiceName"
    Write-Ok "nginx config written"

    Write-Step "Testing and reloading nginx..."
    Invoke-Remote "nginx -t" | ForEach-Object { Write-Host "    $_" }
    Invoke-Remote "systemctl reload nginx"
    Write-Ok "nginx reloaded"
}

# ── 8. Health check ────────────────────────────────────────────────────────────
function Test-Deployment {
    Write-Step "Running health check..."
    Start-Sleep 2
    $result = (Invoke-Remote "curl -sf http://localhost/health" -AllowFail) -join ""
    if ($result -match "ok") {
        Write-Ok "Health: $result"
    } else {
        Write-Warn "Health check returned: $result"
        Write-Warn "Check logs: journalctl -u $ServiceName -n 30"
    }
}

# ── Main ───────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
Write-Host "  |      Telegram Relay -- Deploy            |" -ForegroundColor Cyan
Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
Write-Host ""

Assert-LocalTools
Publish-App
Connect-Server
Assert-ServerRequirements
Deploy-Files
Install-Service
Install-NginxConfig
Test-Deployment

Remove-SSHSession -SessionId $Script:Session.SessionId | Out-Null

Write-Host ""
Write-Host "  +------------------------------------------+" -ForegroundColor Green
Write-Host "  |         Deployment complete!             |" -ForegroundColor Green
Write-Host "  +------------------------------------------+" -ForegroundColor Green
Write-Host ""
Write-Host "  Health    : http://$SERVER_IP/health"
Write-Host "  WebSocket : ws://$SERVER_IP`:$WsPort/ws  (API key in JSON payload)"
Write-Host ""
Write-Host "  Config : ssh ${SERVER_USER}@${SERVER_IP} 'nano $DeployDir/appsettings.json && systemctl restart $ServiceName'"
Write-Host "  Logs   : ssh ${SERVER_USER}@${SERVER_IP} 'journalctl -u $ServiceName -f'"
Write-Host ""
Write-Host "  cTrader bot params:"
Write-Host "    Relay Server URL  => ws://$SERVER_IP`:$WsPort"
Write-Host "    API Key           => (value from appsettings.json)"
Write-Host "    Telegram Chat IDs => comma-separated IDs"
Write-Host ""
