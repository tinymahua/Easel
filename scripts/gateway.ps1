$ErrorActionPreference = 'Stop'
$Profile = 'easel'
$Root = Split-Path -Parent $PSScriptRoot
$LogFile = Join-Path $env:TEMP 'easel-gateway.log'
$ErrorLogFile = Join-Path $env:TEMP 'easel-gateway.error.log'
$ConfigDir = Join-Path $HOME ".openclaw-$Profile"
$Port = 18789

function Test-Gateway {
    try { Invoke-WebRequest "http://127.0.0.1:$Port/healthz" -UseBasicParsing -TimeoutSec 2 | Out-Null; return $true }
    catch { return $false }
}

function Get-GatewayProcess {
    Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" |
        Where-Object { $_.CommandLine -match "openclaw.*--profile\s+$Profile.*gateway" } |
        Select-Object -First 1
}

function Stop-Gateway {
    $process = Get-GatewayProcess
    if ($process) { Stop-Process -Id $process.ProcessId -Force; Write-Host '[easel] Gateway stopped' }
    else { Write-Host '[easel] Gateway was not running' }
}

switch ($args[0]) {
    'start' {
        if (Test-Gateway) { Write-Host '[easel] Gateway already running'; break }
        New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
        Write-Host "[easel] Starting Easel gateway (profile: $Profile)..."
        # 原始事件流由 gateway 进程按自己的 env 写到单个共享文件（web/app.py tail 它做流式/思考流）。
        # 注意：`openclaw agent` 客户端没有 --raw-stream 标志，必须在这里、真正跑模型的 gateway 上开启
        # （对齐 gateway.sh:124-126）。web 端默认 SHARED_RAW_STREAM=/tmp/easel-raw-stream.jsonl，
        # Windows 上 /tmp 解析为「当前盘符根\tmp\...」，这里按项目所在盘显式对齐同一绝对路径；
        # 若设了 EASEL_RAW_STREAM_PATH 则以它为准。
        $RawStreamPath = $env:EASEL_RAW_STREAM_PATH
        if (-not $RawStreamPath) { $RawStreamPath = Join-Path (Split-Path $Root -Qualifier) 'tmp\easel-raw-stream.jsonl' }
        $env:OPENCLAW_RAW_STREAM = '1'
        $env:OPENCLAW_RAW_STREAM_PATH = $RawStreamPath
        New-Item -ItemType Directory -Force -Path (Split-Path $RawStreamPath) | Out-Null
        Set-Content -Path $RawStreamPath -Value '' -NoNewline  # 每次起 gateway 清空，避免无限增长/读到上次残留
        # http 直连路径下 agent 跑在 gateway 进程里，拿不到每轮注入的客户端 env：
        # 在这里按 openclaw 版本决定技能是否可用选项卡片（对齐 gateway.sh:127-135；解析失败按 0 退化成文字问答）
        $Cards = '0'
        try {
            $VerLine = (& openclaw --version 2>$null | Select-Object -First 1)
            if ($VerLine -match '(\d+)\.(\d+)\.') {
                if ([int]$Matches[1] -gt 2026 -or ([int]$Matches[1] -eq 2026 -and [int]$Matches[2] -ge 9)) { $Cards = '1' }
            }
        } catch { }
        $env:EASEL_ASKUSER_CARDS = $Cards
        $command = "openclaw --profile $Profile gateway run --force --allow-unconfigured --bind loopback"
        Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Command', $command `
            -WorkingDirectory $Root -RedirectStandardOutput $LogFile -RedirectStandardError $ErrorLogFile -WindowStyle Hidden | Out-Null
        $ready = $false
        1..20 | ForEach-Object {
            if (-not $ready) {
                if (Test-Gateway) { $ready = $true }
                else { Start-Sleep -Seconds 1 }
            }
        }
        if ($ready) { Write-Host '[easel] Gateway started' }
        else { Write-Error "Gateway 启动失败；请检查 $LogFile 和 $ErrorLogFile"; exit 1 }
    }
    'stop' { Stop-Gateway }
    'restart' { Stop-Gateway; Start-Sleep -Seconds 2; & $PSCommandPath start }
    'status' {
        if (Test-Gateway) { Write-Host "[easel] Gateway running (profile: $Profile)" }
        else { Write-Host '[easel] Gateway not running' }
    }
    'logs' { Get-Content $LogFile -Wait }
    default { Write-Host 'Usage: gateway.ps1 {start|stop|restart|status|logs}'; exit 1 }
}
