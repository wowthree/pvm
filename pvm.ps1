# PVM - PHP Version Manager (NTS x64 Only)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ProgressPreference = 'SilentlyContinue'

$root = $PSScriptRoot
$configPath = Join-Path $root "config.json"
$cachePath = Join-Path $root "cache.json"
$currentLink = Join-Path $root "current"

# 初始化配置
if (-not (Test-Path $configPath)) {
    @{ proxy = ""; arch = "nts-x64" } | ConvertTo-Json | Set-Content $configPath
}

$conf = Get-Content $configPath | ConvertFrom-Json

function Get-Proxy {
    if ($conf.proxy) { return @{ Proxy = $conf.proxy } } else { return @{} }
}

# 同步环境变量
function Update-Env-Path {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $pvmCurrent = $currentLink
    $pvmRoot = $root
    $needsUpdate = $false
    
    $requiredPath = @($pvmRoot, $pvmCurrent)

	foreach ($path in $requiredPath) {
		if ($userPath -notlike "$path;*") {
            # 先移除可能存在的旧记录（防止重复），再把新的加在最前面
            $userPath = "$path;" + ($userPath -replace [regex]::Escape("$path;"), "")
            $needsUpdate = $true
        }
	}

    if ($needsUpdate) {
		[Environment]::SetEnvironmentVariable("Path", $userPath, "User")
        Write-Host ">>> 已更新系统环境变量 (Path)，请【重启终端】以生效。" -ForegroundColor Yellow
        Write-Host ">>> 当前生效目录: $pvmRoot" -ForegroundColor Gray
        Write-Host ">>> 当前 PHP 链接: $pvmCurrent" -ForegroundColor Gray
    } else {
        Write-Host ">>> 环境变量已是最新状态。" -ForegroundColor Green
    }
}

# 同步远程索引
function Update-Remote-Cache {
    Write-Host "正在同步 PHP 官网 NTS x64 索引..." -ForegroundColor Cyan
    $sources = @(
        @{ name = "Stable"; url = "https://windows.php.net/downloads/releases/" },
        @{ name = "Archive"; url = "https://windows.php.net/downloads/releases/archives/" }
    )
    
    $rawList = @()
    $proxyParams = Get-Proxy
    # 正则：捕获组1是版本号 (8.4.4)，捕获组0是完整名 (php-8.4.4-nts-Win32-vs17-x64.zip)
    $pattern = '>php-(\d+\.\d+\.\d+)-nts-Win32-[^<>]*?-x64\.zip<'

    foreach ($src in $sources) {
        try {
            $html = Invoke-WebRequest -Uri $src.url -UseBasicParsing @proxyParams
            $matches = [regex]::Matches($html.Content, $pattern)
            foreach ($m in $matches) {
                $pureFileName = $m.Value -replace '^>', '' -replace '<$', ''
                $rawList += [PSCustomObject]@{ 
                    version = $m.Groups[1].Value; 
                    fullName = $pureFileName; 
                    baseUrl = $src.url 
                }
            }
        } catch { Write-Warning "跳过无法访问的地址: $($src.url)" }
    }

    if ($rawList.Count -eq 0) {
        Write-Error "未找到符合条件的 NTS x64 版本，请检查网络。"
        return
    }

#	$filtered = $rawList | Sort-Object { [version]$_.version } -Descending -Unique
	
    # 过滤：按大版本(X.Y)分组，仅保留每组中最新的 Patch(Z)
    $filtered = $rawList | Group-Object { $_.version -replace '\.\d+$', '' } | ForEach-Object {
        $_.Group | Sort-Object { [version]$_.version } -Descending | Select-Object -First 1
    } | Sort-Object { [version]$_.version } -Descending

    $filtered | ConvertTo-Json | Set-Content $cachePath
    Write-Host "成功！已从 Stable 和 Archive 目录缓存了 $($filtered.Count) 个大版本的最新记录。" -ForegroundColor Green
}

function Invoke-PhpSetup {
	param([string]$version)
    $phpDir = Join-Path $root $version
    $iniTemplate = Join-Path $phpDir "php.ini-development"
    $ini = Join-Path $phpDir "php.ini"

    if (-not (Test-Path $phpDir)) { Write-Error "找不到版本 $version"; return }
    if (-not (Test-Path $iniTemplate)) { Write-Warning "找不到 ini 模板，跳过配置"; return }

    Write-Host ">>> 正在配置 PHP $version 的 php.ini..." -ForegroundColor Cyan
    Copy-Item $iniTemplate $ini -Force

    # 核心配置列表（适配 Webman + SQLite + 开发环境）
    (Get-Content $ini) -replace ';extension_dir = "ext"', 'extension_dir = "ext"' `
		-replace 'memory_limit = 128M', 'memory_limit = 512M' `
        -replace ';extension=pdo_sqlite', 'extension=pdo_sqlite' `
        -replace ';extension=sqlite3', 'extension=sqlite3' `
        -replace ';extension=gd', 'extension=gd' `
        -replace ';extension=curl', 'extension=curl' `
        -replace ';extension=fileinfo', 'extension=fileinfo' `
        -replace ';extension=mbstring', 'extension=mbstring' `
        -replace ';extension=openssl', 'extension=openssl' `
        -replace ';extension=exif', 'extension=exif' `
        -replace ';extension=intl', 'extension=intl' `
        -replace ';extension=sockets', 'extension=sockets' `
        -replace ';extension=zip', 'extension=zip' `
        -replace ';zend_extension=opcache', 'zend_extension=opcache' `
        -replace ';opcache.enable=1', 'opcache.enable=1' `
        -replace ';opcache.enable_cli=0', 'opcache.enable_cli=1' `
        -replace ';opcache.memory_consumption=128', 'opcache.memory_consumption=128' `
        -replace ';opcache.interned_strings_buffer=8', 'opcache.interned_strings_buffer=16' `
        -replace ';opcache.max_accelerated_files=10000', 'opcache.max_accelerated_files=20000' `
        -replace ';opcache.jit_buffer_size=0', 'opcache.jit_buffer_size=128M' `
		-replace ';opcache.jit=tracing', 'opcache.jit=1255' `
        -replace ';opcache.validate_timestamps=1', 'opcache.validate_timestamps=1' `
        -replace ';opcache.revalidate_freq=2', 'opcache.revalidate_freq=0' | Set-Content $ini

    Write-Host ">>> PHP $version 配置完成！" -ForegroundColor Green
}

# 3. 命令路由
$action = $args[0]
$param = $args[1]
$extra = $args[2]

switch ($action) {
	"init" { 
		Write-Host ">>> 正在初始化 PVM 运行环境..." -ForegroundColor Cyan
        
        $batPath = Join-Path $root "pvm.bat"
        $batContent = "@powershell -NoProfile -ExecutionPolicy RemoteSigned -File `"%~dp0pvm.ps1`" %*"
        $batContent | Set-Content $batPath -Encoding Ascii
        Write-Host ">>> 已创建 pvm.bat 别名。" -ForegroundColor Gray

        Update-Env-Path
        
        if (-not (Test-Path $currentLink)) {
            Write-Host ">>> 提示: 尚未设置当前版本，请运行 'pvm list remote' 查看并安装。" -ForegroundColor Gray
        }
	}
	 
	"setup" {
        if (!$param) { Write-Error "请指定要配置的版本号，例如: pvm setup 8.4.4"; break }
        Invoke-PhpSetup $param
	}
	
    "update" { Update-Remote-Cache }

    "list" {
        $activeVer = ""
        if (Test-Path $currentLink) { 
            $activeVer = (Get-Item $currentLink).Target -split "\\" | Select-Object -Last 1 
        }

        Write-Host "--- 本地已安装 ---" -ForegroundColor Yellow
        Get-ChildItem $root -Directory | Where-Object { $_.Name -match "^\d+\.\d+\.\d+$" } | ForEach-Object {
            $isCurrent = ($_.Name -eq $activeVer)
            $prefix = if ($isCurrent) { "* " } else { "  " }
            
            # 核心修复：先确定颜色
            $color = "White"
            if ($isCurrent) { $color = "Green" }
            
            Write-Host "$prefix $($_.Name)" -ForegroundColor $color
        }

        if ($param -eq "remote") {
            if (-not (Test-Path $cachePath)) { Update-Remote-Cache }
            $cache = Get-Content $cachePath | ConvertFrom-Json
            Write-Host "`n--- 远程版本 (NTS x64) ---" -ForegroundColor Gray
           # $cache | ForEach-Object { Write-Host "  $($_.version)" }
			
			$versions = $cache.version
			$cellWidth = 18  # 定义每个版本号占用的固定宽度（含间距）
			$windowWidth = $Host.UI.RawUI.WindowSize.Width - 5 # 获取窗口宽度，减去缩进缓冲
			
			$columns = [Math]::Max(1, [Math]::Floor($windowWidth / $cellWidth))
			$rowCount = [Math]::Ceiling($versions.Count / $columns)
			
			for ($r = 0; $r -lt $rowCount; $r++) {
				$rowString = "  "
				for ($c = 0; $c -lt $columns; $c++) {
					# 计算当前行、当前列在原数组中的索引
					$index = $r + ($c * $rowCount)
					if ($index -lt $versions.Count) {
						$rowString += "$($versions[$index])".PadRight($cellWidth)
					}
				}
				Write-Host $rowString -ForegroundColor Gray
			}
        }
    }

    "install" {
        if (-not (Test-Path $cachePath)) { Update-Remote-Cache }
        $cache = Get-Content $cachePath | ConvertFrom-Json
        $target = $cache | Where-Object { $_.version -eq $param }
        
        if (-not $target) { Write-Error "找不到版本 $param"; break }
        
        $dest = Join-Path $root $param
        if (Test-Path $dest) { Write-Host "版本 $param 已存在"; break }

        $downloadUrl = $target.baseUrl + $target.fullName
        $zipPath = Join-Path $root "php-$param-tmp.zip"

        try {
            if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
            Write-Host "正在下载 $downloadUrl ..." -ForegroundColor Green

            # 在 PS7 中直接使用带有进度条的下载
            $ProgressPreference = 'Continue'
            $proxyParams = Get-Proxy
            Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath @proxyParams
            
            # 校验文件大小，如果小于 1MB 肯定是下载失败了
            if ((Get-Item $zipPath).Length -lt 1MB) { throw "下载的文件不完整或为空，请检查网络或代理设置。" }

            Write-Host "`n>>> 下载完成，正在解压..." -ForegroundColor Cyan
            $ProgressPreference = 'SilentlyContinue'
            Add-Type -AssemblyName "System.IO.Compression.FileSystem" > $null
            Expand-Archive -Path $zipPath -DestinationPath $dest -Force
            Remove-Item $zipPath
            
            # 自动化配置 php.ini
            Invoke-PhpSetup $param
            
            Write-Host "安装完成！" -ForegroundColor Green
        } catch { 
			if ($outputStream) { $outputStream.Close() }
			Write-Error "安装失败: $($_.Exception.Message)" 
		}
    }

    "use" {
		if (-not $param) { Write-Error "请输入版本号"; break }
        $targetDir = Join-Path $root $param
        if (-not (Test-Path $targetDir)) { Write-Error "版本 $param 未安装"; break }
        
        if (Test-Path $currentLink) { Remove-Item $currentLink -Force }
        New-Item -ItemType SymbolicLink -Path $currentLink -Target $targetDir | Out-Null
        
        Write-Host "已切换至 PHP $param" -ForegroundColor Green
    }

    "config" {
        if ($param -and $extra) {
            $conf.$param = $extra
            $conf | ConvertTo-Json | Set-Content $configPath
            Write-Host "配置 $param 已更新为 $extra" -ForegroundColor Green
        } else {
            $conf | Out-String | Write-Host
        }
    }

    "uninstall" {
        $target = Join-Path $root $param
        if (Test-Path $target) { Remove-Item $target -Recurse -Force; Write-Host "已卸载 $param" }
    }

    default {
        Write-Host "PVM - PHP Version Manager (NTS x64)"
        Write-Host "  pvm init               初始化ENV"
        Write-Host "  pvm update             同步远程索引"
        Write-Host "  pvm list [remote]      查看本地/远程版本"
        Write-Host "  pvm install <ver>      安装指定版本"
        Write-Host "  pvm uninstall <ver>    卸载指定版本"
        Write-Host "  pvm use <ver>          切换版本"
        Write-Host "  pvm setup <ver>        配置开发环境php.ini"
    }
}