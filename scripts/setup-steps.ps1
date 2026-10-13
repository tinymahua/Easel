# 注意：本文件为 UTF-8 with BOM。Windows PowerShell 5.1 需 BOM 才能正确解析中文字符串（否则报「语法错误」）；请勿移除。
# Easel 安装分步旁路脚本：把 setup.ps1 的「检测→安装→配置→启动」拆成可单独执行的子命令。
# setup.ps1 本身保持原样不动；本脚本与其逻辑同源（分组搬移），可按需只跑其中一步。
#
# 用法（在项目根目录下）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-steps.ps1 check     # 只检测环境（只报告，不安装）
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-steps.ps1 install   # 安装依赖（venv/openclaw/pip/前端/Playwright）
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-steps.ps1 config    # OpenClaw profile 初始化与全部配置写入
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-steps.ps1 start     # 启动 Gateway
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-steps.ps1 fix-port  # 修复 gateway 端口与 Easel 期望不一致的问题
#
# 建议顺序：check → install → config → start。环境类安装（Node/Python/FFmpeg）更适合手动 winget，
# check 只负责告诉你缺什么，不替你装。
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Venv = Join-Path $Root '.venv'
$Python = Join-Path $Venv 'Scripts\python.exe'
$env:PYTHONUTF8 = '1'

function Info($Message) { Write-Host "[easel] $Message" -ForegroundColor Cyan }
function Ok($Message) { Write-Host "  [OK] $Message" -ForegroundColor Green }
function Miss($Message) { Write-Host "  [--] $Message" -ForegroundColor Yellow }
function Fail($Message) { Write-Error $Message; exit 1 }
function Require-Command($Name, $Hint) { if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { Fail "$Name 未找到。$Hint" } }
function Read-EnvFile($Path) {
    $values = @{}
    if (Test-Path $Path) { Get-Content $Path | ForEach-Object { if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') { $values[$matches[1]] = $matches[2].Trim().Trim('"').Trim("'") } } }
    return $values
}
function Read-Secret($Prompt) {
    $secure = Read-Host $Prompt -AsSecureString
    return [System.Net.NetworkCredential]::new('', $secure).Password
}
function OpenClaw-Config($Key, $Value, [switch]$Json) {
    $arguments = @('--profile','easel','config','set',$Key,$Value)
    if ($Json) { $arguments += '--strict-json' }
    & openclaw @arguments 2>&1 | Where-Object { $_ -notmatch '^No change$' }
    if ($LASTEXITCODE -ne 0) { Fail "OpenClaw 配置失败：$Key" }
}
# 尽力而为版：写入失败不 Fail，只返回是否成功，用于探测不同 OpenClaw 版本接受哪套配置 key。
function Try-OpenClawConfig($Key, $Value, [switch]$Json) {
    $arguments = @('--profile','easel','config','set',$Key,$Value)
    if ($Json) { $arguments += '--strict-json' }
    & openclaw @arguments 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}
# JSON 值的配置写入。Windows PowerShell 5.1（系统自带版本）向原生程序传参时会剥掉字符串里的
# 双引号：任何含 JSON 的 config set 都会变成裸键值、--strict-json 解析失败（见 issue #41）。
# 这里改走 --batch-file：argv 里只出现临时文件路径（无引号字符），JSON 从文件读，5.1/7 行为一致。
function OpenClaw-ConfigBatch($Operations) {
    $batchPath = Join-Path ([System.IO.Path]::GetTempPath()) "easel-config-set-$(Get-Random).json"
    try {
        [System.IO.File]::WriteAllText($batchPath, (ConvertTo-Json -InputObject $Operations -Depth 40 -Compress))
        & openclaw --profile easel config set --batch-file $batchPath 2>&1 | Where-Object { $_ -notmatch '^No change$' }
        if ($LASTEXITCODE -eq 0) { return }
        # 老版本 openclaw 不认 --batch-file：退回逐条写入（PS7 可用；Windows PS5.1 下请升级 openclaw）
        Write-Warning '当前 OpenClaw 不支持 --batch-file，退回逐条写入；建议 npm i -g openclaw@latest 升级。'
        foreach ($op in $Operations) {
            OpenClaw-Config $op.path (ConvertTo-Json -InputObject $op.value -Depth 40 -Compress) -Json
        }
    } finally { Remove-Item $batchPath -Force -ErrorAction SilentlyContinue }
}
# 原子写入 anthropic provider。部分 OpenClaw 版本（如 2026.3.x）的 schema 要求 provider 一次性带齐
# baseUrl + models，逐字段 config set 会因中间态缺字段而整体校验失败（baseUrl/models: received undefined）。
# 用 venv Python 生成 JSON，避开 ConvertTo-Json 对空数组的序列化坑；整块替换也会顺带清掉旧的残留 header。
function Write-AnthropicProvider($BaseUrl, $ApiKey, $ApiKeyHeader, $AnthropicVersion) {
    $env:A_BASE_URL = $BaseUrl
    $env:A_API_KEY = $ApiKey
    $env:A_HDR = $ApiKeyHeader
    $env:A_VER = $AnthropicVersion
    $seed = @'
import json, os
p = {"baseUrl": os.environ["A_BASE_URL"], "apiKey": os.environ["A_API_KEY"], "models": []}
hdr = os.environ.get("A_HDR"); ver = os.environ.get("A_VER")
if hdr or ver:
    h = {}
    if hdr: h[hdr] = os.environ["A_API_KEY"]
    if ver: h["anthropic-version"] = ver
    p["headers"] = h
print(json.dumps(p))
'@ | & $Python -
    Remove-Item Env:A_BASE_URL, Env:A_API_KEY, Env:A_HDR, Env:A_VER -ErrorAction SilentlyContinue
    OpenClaw-ConfigBatch @(@{ path = 'models.providers.anthropic'; value = ($seed | ConvertFrom-Json) })
}
function Is-UsableKey($Value) { return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -notmatch 'REPLACE_ME|your[-_ ]?api[-_ ]?key' }
# 解析可用的 Python 启动方式（python → py -3 逐级回退），返回 @{ command; args }。
# Windows 上 python 可能是 Microsoft Store 的假别名（存在但一跑就失败），必须实际执行一次验证。
function Resolve-Python {
    $pythonCommand = (Get-Command python -ErrorAction SilentlyContinue).Source
    if ($pythonCommand) { & $pythonCommand --version *> $null; if ($LASTEXITCODE -ne 0) { $pythonCommand = $null } }
    if (-not $pythonCommand -and (Get-Command py -ErrorAction SilentlyContinue)) { $pythonCommand = (Get-Command py).Source; $pythonArgs = @('-3') } else { $pythonArgs = @() }
    if (-not $pythonCommand) { return $null }
    return @{ command = $pythonCommand; args = $pythonArgs }
}

# ============================================================
# check — 环境检测（只报告，不安装；缺失不中断，最后汇总）
# ============================================================
function Step-Check {
    Write-Host "`nEasel · 环境检测（只报告，不安装）`n" -ForegroundColor Magenta
    $problems = @()

    foreach ($name in @('git','node','npm','ffmpeg')) {
        if (Get-Command $name -ErrorAction SilentlyContinue) { Ok $name } else { $problems += $name; Miss "$name 未找到" }
    }

    if (Get-Command node -ErrorAction SilentlyContinue) {
        # 跟随 openclaw@latest 的引擎要求（当前 2026.9.x 需要 Node >=24.16.0 <25 || >=26.1.0，25.x/26.0 被排除）。
        $nodeParts = (& node -p 'process.versions.node').Split('.') | ForEach-Object { [int]$_ }
        $nodeOk = ($nodeParts[0] -eq 24 -and $nodeParts[1] -ge 16) -or ($nodeParts[0] -eq 26 -and $nodeParts[1] -ge 1) -or ($nodeParts[0] -ge 27)
        if ($nodeOk) { Ok "Node.js $($nodeParts -join '.')（满足 openclaw@latest 引擎要求）" }
        else { $problems += 'node 版本'; Miss "Node $($nodeParts -join '.') 不满足要求（需 24.16+ / 26.1+ / 27+；25.x 与 26.0 被排除）" }
    }

    $py = Resolve-Python
    if ($py) {
        & $py.command @($py.args) -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)'
        if ($LASTEXITCODE -eq 0) { Ok "Python 3.10+（$($py.command)）" }
        else { $problems += 'python 版本'; Miss 'Python 版本低于 3.10' }
    } else { $problems += 'python'; Miss '未找到可运行的 Python 3' }

    if (Test-Path $Python) { Ok "venv（$Venv）" } else { $problems += 'venv'; Miss "venv 不存在（运行 install 或手动创建：python -m venv .venv）" }
    if (Get-Command openclaw -ErrorAction SilentlyContinue) { Ok 'openclaw' } else { $problems += 'openclaw'; Miss 'openclaw 未安装（运行 install，或手动 npm i -g openclaw@latest）' }

    Write-Host ''
    if ($problems.Count -eq 0) {
        Write-Host '  环境就绪，可继续 config / start。' -ForegroundColor Green
    } else {
        Write-Host "  缺失 $($problems.Count) 项：$($problems -join '、')" -ForegroundColor Yellow
        Write-Host '  建议手动安装（winget）后重跑 check 确认，或运行本脚本 install 自动安装。' -ForegroundColor Yellow
        exit 1
    }
}

# ============================================================
# install — 依赖安装（venv / openclaw / pip / Web 前端 / Playwright）
# 环境级软件（Node/Python/FFmpeg）不在此列，请用 check 查缺后手动安装。
# ============================================================
function Step-Install {
    Write-Host "`nEasel · 安装依赖`n" -ForegroundColor Magenta

    $py = Resolve-Python
    if (-not $py) { Fail '未找到可运行的 Python 3；请先安装 Python 3.10+（可先运行 check 查看缺失项）。' }
    & $py.command @($py.args) -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)'
    if ($LASTEXITCODE -ne 0) { Fail 'Python 3.10+ 是必需依赖。' }

    if (-not (Test-Path $Venv)) { Info '创建 Python 虚拟环境...'; & $py.command @($py.args) -m venv $Venv }
    if (-not (Test-Path $Python)) { Fail 'Python venv 创建失败。' }

    Info '安装 OpenClaw...'
    if (-not (Get-Command openclaw -ErrorAction SilentlyContinue)) { & npm install -g openclaw@latest --loglevel warn; if ($LASTEXITCODE -ne 0) { Fail 'OpenClaw 安装失败。' } }
    Require-Command 'openclaw' '请确认 npm 全局 bin 已加入 PATH。'

    Info '安装 Easel Python 依赖...'
    & $Python -m pip install --upgrade pip --progress-bar on
    if ($LASTEXITCODE -ne 0) { Fail 'pip 升级失败。' }
    & $Python -m pip install -e $Root --progress-bar on
    if ($LASTEXITCODE -ne 0) { Fail 'Easel Python 依赖安装失败。' }

    Info '构建 Web 前端...'
    $Frontend = Join-Path $Root 'web\frontend'
    Push-Location $Frontend
    try {
        & npm install
        if ($LASTEXITCODE -ne 0) { Fail 'Web 前端依赖安装失败。' }
        & npm run build
        if ($LASTEXITCODE -ne 0) { Fail 'Web 前端构建失败。' }
    } finally { Pop-Location }

    Info '安装 Playwright Chromium...'
    & $Python -m playwright install chromium
    if ($LASTEXITCODE -ne 0) { Fail 'Playwright Chromium 安装失败。' }

    Ok '依赖安装完成'
}

# ============================================================
# config — OpenClaw profile 初始化 + workspace 同步 + LLM/网关配置写入
# 前置：openclaw 已安装、venv 已就绪（先跑 check / install）。
# ============================================================
function Step-Config {
    Write-Host "`nEasel · OpenClaw 配置`n" -ForegroundColor Magenta
    Require-Command 'openclaw' '请先运行 install，或手动安装：npm i -g openclaw@latest。'
    if (-not (Test-Path $Python)) { Fail "venv 不存在（$Venv）；请先运行 install。" }

    # 提前读 .env：用于 pre-flight 修复 openclaw.json 时回填 apiKey/baseUrl。
    # 下方还有一次 re-read——用户在交互提示里补入 key 后需要刷新 $envValues。
    $envPath = Join-Path $Root '.env'
    if (-not (Test-Path $envPath)) { Copy-Item (Join-Path $Root '.env.example') $envPath }
    $envValues = Read-EnvFile $envPath

    Info 'pre-flight：清理 openclaw.json 残留 null 与补齐缺失必填字段...'
    # 部分 OpenClaw 版本执行 config unset 后会把字段留成 null 而非真正删除该键，
    # 一旦落盘就再也无法通过 config set/doctor --fix 修复（每次校验都先失败）。
    # 此外某些 provider 还可能整体缺 api / apiKey / baseUrl / model.name|reasoning|input 等
    # 必填字段，导致 onboard 启动校验直接拒绝运行。
    # 这里在写入任何配置前，原地：
    #   1) 清空所有 null 叶子节点；
    #   2) 按 provider id 推断 api 协议（anthropic / openai-completions）；
    #   3) 缺失的 apiKey / baseUrl 用 .env 对应字段回填，baseUrl 缺时给协议默认 URL；
    #   4) 每个 model 缺 name/reasoning/input 时补齐。
    # 这一步必须在 onboard 之前跑——onboard 会校验现存配置。
    $openclawJson = Join-Path $HOME '.openclaw-easel\openclaw.json'
    if (Test-Path $openclawJson) {
        # 把 .env 写到临时 JSON 文件再把路径传给 Python，避免把 JSON 走 argv 时被 PS / Windows
        # 拆分引号或空格导致 json.loads 报 Expecting property name 之类错误。
        $envJsonPath = Join-Path ([System.IO.Path]::GetTempPath()) "easel-heal-env-$(Get-Random).json"
        try {
            $envValues | ConvertTo-Json -Compress | Set-Content -Path $envJsonPath -Encoding UTF8 -NoNewline
            @'
import json, os, sys

path = sys.argv[1]
env = {}
if len(sys.argv) > 2 and os.path.isfile(sys.argv[2]):
    try:
        with open(sys.argv[2]) as f:
            env = json.load(f)
    except Exception:
        env = {}
with open(path) as f:
    config = json.load(f)


def strip_nulls(node):
    if isinstance(node, dict):
        for key in list(node.keys()):
            value = node[key]
            if value is None:
                del node[key]
            elif isinstance(value, (dict, list)):
                strip_nulls(value)
    elif isinstance(node, list):
        for item in node:
            strip_nulls(item)


def protocol_for(pid):
    return "anthropic" if "anthropic" in pid.lower() else "openai-completions"


def key_envs_for(pid):
    if "anthropic" in pid.lower():
        for k in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "EASEL_LLM_API_KEY"):
            if env.get(k):
                return env[k]
    else:
        if env.get("OPENAI_API_KEY"):
            return env["OPENAI_API_KEY"]
    return None


def url_for(pid):
    if "anthropic" in pid.lower():
        return env.get("ANTHROPIC_BASE_URL") or env.get("EASEL_LLM_BASE_URL") or "https://api.anthropic.com"
    return env.get("OPENAI_BASE_URL") or "https://api.openai.com/v1"


providers = config.setdefault("models", {}).setdefault("providers", {})

# Pass 1：原地清空 null 叶子
strip_nulls(providers)

# Pass 2：补齐 provider / model 必填字段
changed = False
for pid, p in list(providers.items()):
    if not isinstance(p, dict):
        continue
    if "api" not in p:
        p["api"] = protocol_for(pid)
        changed = True
    if "apiKey" not in p:
        k = key_envs_for(pid)
        if k:
            p["apiKey"] = k
            changed = True
    if "baseUrl" not in p:
        p["baseUrl"] = url_for(pid)
        changed = True
    if isinstance(p.get("models"), list):
        for m in p["models"]:
            if not isinstance(m, dict):
                continue
            if "name" not in m and "id" in m:
                m["name"] = m["id"]
                changed = True
            if "reasoning" not in m:
                m["reasoning"] = False
                changed = True
            if "input" not in m:
                m["input"] = ["text"]
                changed = True

if changed:
    with open(path, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
'@ | & $Python - $openclawJson $envJsonPath
        } finally {
            Remove-Item $envJsonPath -Force -ErrorAction SilentlyContinue
        }
    }

    Info '准备 Easel OpenClaw profile...'
    $onboardHelp = (& openclaw onboard --help 2>&1 | Out-String)
    $onboardArgs = @('--profile','easel','onboard','--non-interactive','--mode','local','--accept-risk')
    foreach ($flag in @('--skip-health','--skip-channels','--skip-skills','--skip-ui','--skip-hooks','--skip-search','--skip-daemon')) {
        if ($onboardHelp -match [regex]::Escape($flag)) { $onboardArgs += $flag }
    }
    if ($onboardHelp -match '--no-install-daemon' -and $onboardHelp -notmatch '--skip-daemon') { $onboardArgs += '--no-install-daemon' }
    & openclaw @onboardArgs 2>&1 | Where-Object { $_ -notmatch '^No change$' }
    if ($LASTEXITCODE -ne 0) { Fail 'OpenClaw profile 初始化失败，请检查上方输出。' }

    Info '同步 skills 与 workspace...'
    # workspace 目标不能写死：OpenClaw 的默认布局变过（2026.6.x 是 ~\.openclaw\workspace-easel，
    # 2026.9.x 起是 ~\.openclaw-easel\workspace）。写死其一就会在另一个版本上装到 agent 不读的
    # 目录里，而这里和 doctor 都照样报成功（issue #19）。统一问 easel\openclaw_workspace.py。
    #
    # 这段有两个 Windows 专属的坑，改动前请先看明白：
    #   1. 顶上是 $ErrorActionPreference='Stop'。此时只要对原生命令做任何 stderr 重定向
    #      （2>$null / 2>&1 / *>），PowerShell 5.1 会把 stderr 的每一行包成 ErrorRecord 抛出
    #      NativeCommandError —— 脚本级终止，下面的回退分支根本轮不到。所以这里**不重定向**，
    #      让 Python 的报错原样显示给用户，只用 $LASTEXITCODE 判成败。
    #   2. PS 5.1 按 [Console]::OutputEncoding（中文系统是 OEM 936）解码原生命令的 stdout，
    #      而 Python 那边输出的是 UTF-8（开头设了 PYTHONUTF8=1，模块里也显式 reconfigure）。
    #      路径含中文时两边对不上就是乱码。把 OutputEncoding 临时钉成 UTF-8，用完还原。
    $workspace = ''
    $prevOutEnc = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
        $wsOut = & $Python (Join-Path $Root 'easel\openclaw_workspace.py')
        if ($LASTEXITCODE -eq 0) { $workspace = ($wsOut | Select-Object -Last 1) }
    } catch {
        Write-Warning "解析 workspace 时出错：$($_.Exception.Message)"
    } finally {
        [Console]::OutputEncoding = $prevOutEnc
    }
    $workspace = "$workspace".Trim()
    if ([string]::IsNullOrWhiteSpace($workspace)) {
        # 走到这里说明 Python 压根没跑起来（解析器内部的逐级退化没机会执行）。先认用户的显式覆盖。
        if ($env:EASEL_OPENCLAW_WORKSPACE) {
            $workspace = $env:EASEL_OPENCLAW_WORKSPACE
        } else {
            $workspace = Join-Path $HOME '.openclaw-easel\workspace'
        }
        Write-Warning "无法向 openclaw 问出 workspace，回退到 $workspace；若 agent 读不到技能，请设 EASEL_OPENCLAW_WORKSPACE 后重跑。"
    }
    Info "  workspace → $workspace"
    $skills = Join-Path $workspace 'skills'
    New-Item -ItemType Directory -Force -Path $skills | Out-Null
    if (Test-Path (Join-Path $Root 'skills\openclaw')) { Copy-Item (Join-Path $Root 'skills\openclaw\*') $skills -Recurse -Force }
    Copy-Item (Join-Path $Root 'openclaw\workspace\*.md') $workspace -Force -ErrorAction SilentlyContinue
    $context = Join-Path $workspace 'CONTEXT.md'
    @"
# Easel 项目路径

项目根目录：$Root
产物输出到：$(Join-Path $Root 'outputs')
用户素材在：$(Join-Path $Root 'assets')
用户画像在：$(Join-Path $Root 'profiles')
"@ | Set-Content -Path $context -Encoding UTF8
    $shared = Join-Path $workspace 'shared'
    if (Test-Path $shared) { Remove-Item $shared -Recurse -Force }
    if (Test-Path (Join-Path $Root 'skills\shared')) { Copy-Item (Join-Path $Root 'skills\shared') $shared -Recurse -Force }
    $profilesLink = Join-Path $workspace 'easel-profiles'
    if (Test-Path $profilesLink) {
        $profileItem = Get-Item $profilesLink -Force
        if ($profileItem.LinkType -ne 'Junction') { Fail "$profilesLink 已存在但不是项目 profiles Junction，请移走后重试。" }
    } else { New-Item -ItemType Junction -Path $profilesLink -Target (Join-Path $Root 'profiles') | Out-Null }
    $outputs = Join-Path $workspace 'outputs'
    New-Item -ItemType Directory -Force -Path (Join-Path $Root 'outputs') | Out-Null
    if (Test-Path $outputs) {
        $outputsItem = Get-Item $outputs -Force
        if ($outputsItem.LinkType -ne 'Junction') { Fail "$outputs 已存在但不是项目 outputs Junction，请移走后重试。" }
    } else { New-Item -ItemType Junction -Path $outputs -Target (Join-Path $Root 'outputs') | Out-Null }

    # 上面已经提前读过 $envValues；这里只在「所有可用 key 都不可用」时提示用户输入。
    if (-not (Is-UsableKey $envValues['ANTHROPIC_API_KEY']) -and -not (Is-UsableKey $envValues['OPENAI_API_KEY']) -and -not (Is-UsableKey $envValues['ANTHROPIC_AUTH_TOKEN']) -and -not (Is-UsableKey $envValues['EASEL_LLM_API_KEY']) -and -not (Is-UsableKey $envValues['OPENAI_MAAS_API_KEY'])) {
        $choice = Read-Host '模型服务：1 Anthropic / 2 OpenAI-compatible / 0 稍后配置 [1]'
        if ($choice -eq '2') { $key = Read-Secret 'OpenAI API Key（不会回显）'; $url = Read-Host 'Base URL [https://api.openai.com/v1]'; $model = Read-Host '模型 [gpt-4o]'; Add-Content $envPath "`nOPENAI_API_KEY=$key`nOPENAI_BASE_URL=$url`nOPENAI_MODEL=$model" }
        elseif ($choice -eq '1' -or [string]::IsNullOrWhiteSpace($choice)) { $key = Read-Secret 'Anthropic API Key（不会回显）'; $model = Read-Host '模型 [anthropic/claude-sonnet-4-6]'; Add-Content $envPath "`nANTHROPIC_API_KEY=$key`nCLAUDE_MODEL=$model" }
    }
    # 重新读 .env：用户在上面的交互选择里可能刚补入了 key，需刷新 $envValues。
    $envValues = Read-EnvFile $envPath

    # 仅当真正写了 anthropic provider 时，才补设它的 provider 级超时（见文末 timeoutSeconds）；
    # 否则会给 OpenAI/MAAS 用户凭空造出一个只有 timeoutSeconds、缺 baseUrl/models 的残缺 anthropic provider。
    $anthropicSynced = $false
    # 注意函数调用外面这对括号不能省：`if (Is-UsableKey $x -and $y)` 会让解析器进入命令模式，
    # 把 `-and` 当成 Is-UsableKey 的参数名（简单函数会把它静默吞进 $args），
    # 于是 ContainsKey 那半边守卫被丢掉且不报错。加括号才让 -and 回到运算符语义。
    if ((Is-UsableKey $envValues['OPENAI_MAAS_API_KEY']) -and $envValues.ContainsKey('OPENAI_MAAS_ENDPOINT')) {
        $model = if ($envValues.ContainsKey('OPENAI_MAAS_MODEL')) { $envValues['OPENAI_MAAS_MODEL'] } else { 'gpt-5.5' }
        $port = if ($envValues.ContainsKey('OPENAI_MAAS_ADAPTER_PORT')) { $envValues['OPENAI_MAAS_ADAPTER_PORT'] } else { '18791' }
        $adapter = Join-Path $Root 'scripts\openai_maas_adapter.py'
        $provider = @{ baseUrl = "http://127.0.0.1:$port/v1"; api = 'openai-completions'; apiKey = 'local-adapter'; timeoutSeconds = 600; request = @{ allowPrivateNetwork = $true }; models = @(@{ id = $model; name = 'OpenAI-compatible model'; reasoning = $true; input = @('text') }); localService = @{ command = $Python; args = @($adapter, '--port', $port); cwd = $Root; healthUrl = "http://127.0.0.1:$port/health"; idleStopMs = 0; env = @{ OPENAI_MAAS_API_KEY = $envValues['OPENAI_MAAS_API_KEY']; OPENAI_MAAS_ENDPOINT = $envValues['OPENAI_MAAS_ENDPOINT']; OPENAI_MAAS_MODEL = $model; OPENAI_MAAS_API_KEY_HEADER = if ($envValues.ContainsKey('OPENAI_MAAS_API_KEY_HEADER')) { $envValues['OPENAI_MAAS_API_KEY_HEADER'] } else { 'Authorization' } } } }
        OpenClaw-ConfigBatch @(@{ path = 'models.providers.rednote-openai'; value = $provider })
        OpenClaw-Config 'agents.defaults.model.primary' "rednote-openai/$model"
    } elseif (Is-UsableKey $envValues['OPENAI_API_KEY']) {
        $model = if ($envValues.ContainsKey('OPENAI_MODEL')) { $envValues['OPENAI_MODEL'] } else { 'gpt-4o' }
        OpenClaw-ConfigBatch @(
            @{ path = 'models.providers.openai.api'; value = 'openai-completions' },
            @{ path = 'models.providers.openai.apiKey'; value = $envValues['OPENAI_API_KEY'] },
            @{ path = 'models.providers.openai.baseUrl'; value = $(if ($envValues.ContainsKey('OPENAI_BASE_URL')) { $envValues['OPENAI_BASE_URL'] } else { 'https://api.openai.com/v1' }) },
            @{ path = 'models.providers.openai.models'; value = @(@{ id = $model; name = 'OpenAI model'; reasoning = $true; input = @('text', 'image') }) },
            @{ path = 'agents.defaults.model.primary'; value = "openai/$model" }
        )
    } elseif ((Is-UsableKey $envValues['EASEL_LLM_API_KEY']) -and $envValues.ContainsKey('EASEL_LLM_BASE_URL')) {
        # 原子写入整块 provider（含 header 与 anthropic-version）；整块替换会顺带清掉旧的专用 header。
        $hdr = if ($envValues.ContainsKey('EASEL_LLM_API_KEY_HEADER')) { $envValues['EASEL_LLM_API_KEY_HEADER'] } else { 'api-key' }
        $ver = if ($envValues.ContainsKey('EASEL_LLM_ANTHROPIC_VERSION')) { $envValues['EASEL_LLM_ANTHROPIC_VERSION'] } else { '2023-06-01' }
        Write-AnthropicProvider $envValues['EASEL_LLM_BASE_URL'] $envValues['EASEL_LLM_API_KEY'] $hdr $ver
        $anthropicSynced = $true
        OpenClaw-Config 'agents.defaults.model.primary' $(if ($envValues.ContainsKey('CLAUDE_MODEL')) { $envValues['CLAUDE_MODEL'] } else { 'anthropic/claude-sonnet-4-6' })
    } elseif ((Is-UsableKey $envValues['ANTHROPIC_AUTH_TOKEN']) -and $envValues.ContainsKey('ANTHROPIC_BASE_URL')) {
        Write-AnthropicProvider $envValues['ANTHROPIC_BASE_URL'] $envValues['ANTHROPIC_AUTH_TOKEN'] '' ''
        $anthropicSynced = $true
        OpenClaw-Config 'agents.defaults.model.primary' $(if ($envValues.ContainsKey('CLAUDE_MODEL')) { $envValues['CLAUDE_MODEL'] } else { 'anthropic/claude-sonnet-4-6' })
    } elseif (Is-UsableKey $envValues['ANTHROPIC_API_KEY']) {
        # 官方 ANTHROPIC_API_KEY 可搭配 ANTHROPIC_BASE_URL 指向自定义代理/网关；未指定时显式指向官方端点，
        # 否则请求会发往默认的 api.anthropic.com，代理网络下会直接超时。provider 由 Write-AnthropicProvider 原子写入，
        # 避免逐字段写入时 baseUrl/models 缺失导致 2026.3.x 报 expected string/array, received undefined。
        $baseUrl = if (-not [string]::IsNullOrWhiteSpace($envValues['ANTHROPIC_BASE_URL'])) { $envValues['ANTHROPIC_BASE_URL'] } else { 'https://api.anthropic.com' }
        Write-AnthropicProvider $baseUrl $envValues['ANTHROPIC_API_KEY'] '' ''
        $anthropicSynced = $true
        OpenClaw-Config 'agents.defaults.model.primary' $(if ($envValues.ContainsKey('CLAUDE_MODEL')) { $envValues['CLAUDE_MODEL'] } else { 'anthropic/claude-sonnet-4-6' })
    }
    $embeddingKeyNames = @('EASEL_EMBEDDING_API_KEY', 'EASEL_EMBEDDINGS_API_KEY', 'OPENAI_EMBEDDING_API_KEY', 'EMBEDDING_API_KEY', 'EMBEDDINGS_API_KEY')
    $embeddingUrlNames = @('EASEL_EMBEDDING_BASE_URL', 'EASEL_EMBEDDINGS_BASE_URL', 'OPENAI_EMBEDDING_BASE_URL', 'EMBEDDING_BASE_URL', 'EMBEDDINGS_BASE_URL')
    $embeddingModelNames = @('EASEL_EMBEDDING_MODEL', 'EASEL_EMBEDDINGS_MODEL', 'OPENAI_EMBEDDING_MODEL', 'EMBEDDING_MODEL', 'EMBEDDINGS_MODEL')
    $embeddingKey = $embeddingKeyNames | Where-Object { Is-UsableKey $envValues[$_] } | Select-Object -First 1
    $embeddingUrl = $embeddingUrlNames | Where-Object { -not [string]::IsNullOrWhiteSpace($envValues[$_]) } | Select-Object -First 1
    $embeddingModel = $embeddingModelNames | Where-Object { -not [string]::IsNullOrWhiteSpace($envValues[$_]) } | Select-Object -First 1
    if ($embeddingKey -and $embeddingUrl -and $embeddingModel) {
        # 记忆检索 schema 位置随 OpenClaw 版本变化：2026.9.x 起在顶层 memory.search.*，之前在 agents.defaults.memorySearch.*。
        # 两者互斥，用「先试新 key、失败再退老 key」自适应：第一条写入既是真实配置也是版本探测。
        if (Try-OpenClawConfig 'memory.search.provider' 'openai-compatible') {
            OpenClaw-Config 'memory.search.enabled' 'true' -Json; OpenClaw-Config 'memory.search.model' $envValues[$embeddingModel]; OpenClaw-Config 'memory.search.remote.baseUrl' $envValues[$embeddingUrl]; OpenClaw-Config 'memory.search.remote.apiKey' $envValues[$embeddingKey]
            Ok "独立向量模型已配置（memory.search）：$($envValues[$embeddingModel])"
        } else {
            OpenClaw-Config 'agents.defaults.memorySearch.provider' 'openai-compatible'; OpenClaw-Config 'agents.defaults.memorySearch.model' $envValues[$embeddingModel]; OpenClaw-Config 'agents.defaults.memorySearch.remote.baseUrl' $envValues[$embeddingUrl]; OpenClaw-Config 'agents.defaults.memorySearch.remote.apiKey' $envValues[$embeddingKey]
            Ok "独立向量模型已配置（memorySearch）：$($envValues[$embeddingModel])"
        }
    } else {
        # 新 schema 用 memory.search.enabled=false 关闭向量检索；老 schema 用 provider=none。
        if (-not (Try-OpenClawConfig 'memory.search.enabled' 'false' -Json)) {
            OpenClaw-Config 'agents.defaults.memorySearch.provider' 'none'
        }
        if (($embeddingKeyNames + $embeddingUrlNames + $embeddingModelNames | Where-Object { $envValues.ContainsKey($_) }).Count -gt 0) { Write-Warning '向量 API 配置不完整，已关闭向量检索；需要同时设置向量 API key、Base URL 和模型名' } else { Info '未配置独立向量 API，使用关键词记忆检索' }
    }
    OpenClaw-Config 'agents.defaults.timeoutSeconds' '7200'; OpenClaw-Config 'gateway.mode' 'local'; OpenClaw-Config 'gateway.bind' 'loopback'; OpenClaw-Config 'gateway.auth.mode' 'none'
    # 对话直连常驻网关（web/app.py 的 http 传输层）要用 OpenAI 兼容端点，而 openclaw 默认不挂这条
    # 路由（chatCompletions.enabled 默认 false），不开则 POST /v1/chat/completions 一律 404、只能
    # 退回每轮 spawn 客户端的老路径。端点只绑 loopback + auth.mode=none 的本机网关，不扩暴露面。
    # 走尽力而为版：老版本没这个 key 时只是拿不到提速，不该让整个安装失败。
    if (-not (Try-OpenClawConfig 'gateway.http.endpoints.chatCompletions.enabled' 'true' -Json)) {
        Info '当前 OpenClaw 不支持 chatCompletions 端点，对话将走每轮启动客户端的兼容路径（可用，只是每轮慢几秒）'
    }
    # 单次 LLM 请求的「空闲超时」。尽力而为：老版本 OpenClaw（如 2026.3.x）的 provider schema 不认识
    # timeoutSeconds，会报 Unrecognized key 并拒绝写入。这里吞掉这条噪音、绝不让它中断安装；
    # 新版本 OpenClaw 才会真正把它调到 600s。想彻底拿到更长超时，请 npm i -g openclaw@latest 升级。
    if ($anthropicSynced) {
        & openclaw --profile easel config set models.providers.anthropic.timeoutSeconds 600 2>&1 |
            Where-Object { $_ -notmatch '^No change$' -and $_ -notmatch '[Uu]nrecognized key' -and $_ -notmatch 'timeoutSeconds' } | Out-Null
    }
    & openclaw --profile easel config validate
    if ($LASTEXITCODE -ne 0) { Fail 'OpenClaw 配置校验失败。' }
    Ok 'OpenClaw 配置完成'
}

# ============================================================
# start — 启动 Gateway
# ============================================================
function Step-Start {
    Write-Host "`nEasel · 启动 Gateway`n" -ForegroundColor Magenta
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\gateway.ps1') start
    if ($LASTEXITCODE -ne 0) { Fail 'Easel Gateway 启动失败。' }
    Ok 'Easel Gateway 启动完成'
    Write-Host "启动 Web：$Venv\Scripts\easel.exe web" -ForegroundColor Cyan
    Write-Host "检查环境：$Venv\Scripts\easel.exe doctor" -ForegroundColor Cyan
}

# ============================================================
# fix-port — 修复 gateway 端口与 Easel 期望不一致的问题
# 背景：openclaw onboard 会自行分配网关端口（曾分配出 37289），而 Easel 全部代码
# （web/app.py、gateway_questions.py、doctor、ping、gateway.ps1）都期望 18789（.env 的
# OPENCLAW_PORT）。onboard 后端口对不上 → gateway.ps1 健康检查永远失败、误报「启动失败」。
# 本命令以 .env 为准把 gateway.port 写回。
# 注意：只写配置，不重启网关；网关正在运行时需重启后生效。
# ============================================================
function Step-FixPort {
    Write-Host "`nEasel · 修复 Gateway 端口`n" -ForegroundColor Magenta
    $envPath = Join-Path $Root '.env'
    $envValues = Read-EnvFile $envPath
    $port = $envValues['OPENCLAW_PORT']
    if ([string]::IsNullOrWhiteSpace($port)) { $port = '18789' }
    Info "将 openclaw gateway.port 设为 $port（Easel 全部代码期望的端口）..."
    OpenClaw-Config 'gateway.port' $port
    Ok "gateway.port = $port"
    Write-Host '若 Gateway 正在运行，需重启才能生效：' -ForegroundColor Cyan
    Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File `"$Root\scripts\gateway.ps1`" restart" -ForegroundColor Cyan
}

switch ($args[0]) {
    'check' { Step-Check }
    'install' { Step-Install }
    'config' { Step-Config }
    'start' { Step-Start }
    'fix-port' { Step-FixPort }
    default {
        Write-Host '用法：setup-steps.ps1 {check|install|config|start|fix-port}'
        Write-Host ''
        Write-Host '  check     只检测环境（只报告，不安装；缺失项列全后汇总）'
        Write-Host '  install   安装依赖（venv/openclaw/pip/Web 前端/Playwright；不含 Node/Python/FFmpeg 等系统软件）'
        Write-Host '  config    OpenClaw profile 初始化 + workspace/skills 同步 + LLM 与网关配置写入 + 校验'
        Write-Host '  start     启动 Gateway（内部调用 scripts\gateway.ps1 start）'
        Write-Host '  fix-port  修复 gateway 端口与 Easel 期望（.env 的 OPENCLAW_PORT，默认 18789）不一致的问题'
        Write-Host ''
        Write-Host '建议顺序：check → install → config → start。每步独立执行，可手动与脚本交替。'
        exit 1
    }
}
