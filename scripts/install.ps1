# ============================================================================
#  install.ps1 — установщик конвейера кадров «АминТако» для Windows
#
#  Запускается из УСТАНОВКА.bat. Приводит компьютер режиссёра к состоянию, в
#  котором воркер (Claude по ВОРКЕР.md) может генерировать кадры, пушить их в
#  репозиторий genvid25/amintako и писать в базу Supabase.
#
#  Делает ВСЁ, что можно автоматизировать. Человеку остаётся только то, что
#  автоматизировать нельзя: логины в аккаунты, подтверждения и первый запуск.
#
#  Каждый шаг проверяет «уже сделано? — пропустить», объясняет действия
#  по-русски и при ошибке останавливается с понятной причиной.
#
#  Ключ -DryRun (он же -Проверка) печатает шаги, ничего не меняя.
#  Файл сохранён в UTF-8 с BOM — иначе Windows PowerShell 5.1 портит кириллицу.
# ============================================================================

param(
    [Alias('Проверка', 'Check')]
    [switch]$DryRun
)

# --- Кодировка консоли: UTF-8, иначе кириллица превратится в кракозябры -------
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding  = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding           = [System.Text.Encoding]::UTF8 } catch {}

# --- TLS 1.2: старые сборки Windows PowerShell по умолчанию берут TLS 1.0 -----
#     и тогда github.com / supabase не отвечают (ошибка рукопожатия).
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

# --- Платформа. В Windows PowerShell 5.1 переменной $IsWindows нет (там $null),
#     в PowerShell 7 на Windows она $true, на macOS/Linux — $false. Так один и
#     тот же скрипт можно прогнать в режиме проверки на другой ОС. --------------
if ($null -ne $IsWindows) { $script:OnWindows = [bool]$IsWindows } else { $script:OnWindows = $true }

# --- Базовые константы -------------------------------------------------------
$script:UserHome   = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$script:Root       = Join-Path $script:UserHome 'amintako'      # сюда кладём проект
$script:RepoSlug   = 'genvid25/amintako'
$script:RepoUrl    = "https://github.com/$script:RepoSlug.git"  # публичный репозиторий, клон без токена
$script:ProfileDir = 'AminTakoWorker'                           # имя папки профиля Chrome для воркера

$script:cfg  = @{}                                              # разобранный .env
$script:attn = New-Object System.Collections.Generic.List[string]  # «осталось руками / внимание»

# ============================================================================
#  Вывод
# ============================================================================
function Head($t) { Write-Host ''; Write-Host "→ $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "  ✓ $t" -ForegroundColor Green }
function Note($t) { Write-Host "  · $t" -ForegroundColor Gray }
function Warn($t) { Write-Host "  ! $t" -ForegroundColor Yellow }

function Stop-Install($msg, $hint) {
    Write-Host ''
    Write-Host "  × $msg" -ForegroundColor Red
    if ($hint) { Write-Host "    $hint" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host 'Установка остановлена. Исправьте причину выше и запустите УСТАНОВКА.bat снова.' -ForegroundColor Red
    exit 1
}

# ============================================================================
#  Вспомогательные функции
# ============================================================================

# Подхватить PATH после установки программ (winget не обновляет PATH текущей сессии).
function Update-Path {
    if (-not $script:OnWindows) { return }
    try {
        $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $u = [Environment]::GetEnvironmentVariable('Path', 'User')
        $env:Path = (@($m, $u) | Where-Object { $_ }) -join ';'
    } catch {}
}

# Установить пакет через winget. Итог проверяет вызывающий (перепроверкой наличия),
# потому что коды выхода winget неоднозначны.
function Install-Winget($id, $name) {
    Note "Устанавливаю $name (winget). Может появиться окно «Разрешить приложению внести изменения?» — нажмите «Да»."
    $a = @('install', '--id', $id, '-e', '--source', 'winget',
           '--accept-package-agreements', '--accept-source-agreements', '--silent')
    & winget @a
}

# Найти рабочий Python. Воркер зовёт его как `py`; если нет — python/python3.
function Get-PyCmd {
    foreach ($c in @('py', 'python', 'python3')) {
        if (Get-Command $c -ErrorAction SilentlyContinue) {
            try {
                $v = & $c --version 2>&1
                if ($LASTEXITCODE -eq 0 -or "$v" -match 'Python') { return $c }
            } catch {}
        }
    }
    return $null
}

# Проверить, что Pillow и openpyxl импортируются.
function Test-PyImport($py) {
    try { & $py -c 'import PIL, openpyxl' 2>$null; return ($LASTEXITCODE -eq 0) } catch { return $false }
}

# Найти chrome.exe по стандартным путям и в реестре App Paths.
function Find-Chrome {
    $paths = @()
    if ($env:ProgramFiles)        { $paths += (Join-Path $env:ProgramFiles        'Google\Chrome\Application\chrome.exe') }
    if (${env:ProgramFiles(x86)}) { $paths += (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe') }
    if ($env:LOCALAPPDATA)        { $paths += (Join-Path $env:LOCALAPPDATA        'Google\Chrome\Application\chrome.exe') }
    foreach ($p in $paths) { if (Test-Path $p) { return $p } }
    foreach ($hive in @('HKLM:', 'HKCU:')) {
        $rk = Join-Path $hive 'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
        try {
            $v = (Get-ItemProperty -Path $rk -ErrorAction Stop).'(default)'
            if ($v -and (Test-Path $v)) { return $v }
        } catch {}
    }
    return $null
}

# Разобрать .env в хеш-таблицу. Комментарии (#) и пустые строки пропускаем.
function Read-DotEnv($path) {
    $h = @{}
    if (-not (Test-Path $path)) { return $h }
    foreach ($line in (Get-Content -LiteralPath $path -Encoding UTF8)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $t.Substring(0, $i).Trim()
        $v = $t.Substring($i + 1).Trim().Trim('"').Trim("'")
        $h[$k] = $v
    }
    return $h
}

# ============================================================================
#  Шаг 1 — окружение
# ============================================================================
function Step-Environment {
    Head 'Шаг 1. Проверка окружения'

    if ($script:OnWindows) {
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            Note ("Система: {0} (сборка {1})" -f $os.Caption, $os.BuildNumber)
            $build = 0; [void][int]::TryParse("$($os.BuildNumber)", [ref]$build)
            if ($build -gt 0 -and $build -lt 17763) {
                Warn 'Старая версия Windows. Нужна Windows 10 версии 1809 или новее, иначе winget недоступен.'
            }
            Ok 'версия Windows определена'
        } catch {
            Note 'Не удалось определить версию Windows (не критично), продолжаю.'
        }
    } else {
        Note 'Это не Windows — режим проверки. Часть шагов будет только показана.'
    }

    # Интернет — проверка безопасная (только чтение), выполняем всегда.
    try {
        [void](Invoke-WebRequest -Uri 'https://github.com' -Method Head -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop)
        Ok 'интернет есть (github.com отвечает)'
    } catch {
        try {
            [void](Invoke-WebRequest -Uri 'https://www.google.com' -Method Head -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop)
            Ok 'интернет есть'
        } catch {
            Stop-Install 'Нет связи с интернетом.' 'Подключите интернет и запустите установку снова.'
        }
    }

    if ($script:OnWindows) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Ok 'winget найден'
        } else {
            Stop-Install 'Не найден winget (менеджер установки Windows).' `
                'Откройте Microsoft Store, установите «Установщик приложений» (App Installer): https://apps.microsoft.com/detail/9NBLGGH4NNS1 — и запустите установку снова.'
        }
    } else {
        Note '(проверка) пропускаю проверку winget — не Windows.'
    }
}

# ============================================================================
#  Шаг 2 — Git
# ============================================================================
function Step-Git {
    Head 'Шаг 2. Git'

    if (Get-Command git -ErrorAction SilentlyContinue) { Ok 'git уже установлен'; return }

    if (-not $script:OnWindows) { Note '(проверка) git не найден; на Windows выполнил бы: winget install --id Git.Git'; return }
    if ($DryRun)                { Note '(проверка) winget install --id Git.Git'; return }

    Install-Winget 'Git.Git' 'Git'
    Update-Path
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $gp = Join-Path $env:ProgramFiles 'Git\cmd'
        if (Test-Path (Join-Path $gp 'git.exe')) { $env:Path = "$env:Path;$gp" }
    }
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Ok 'git установлен'
    } else {
        Stop-Install 'Git установился, но не виден в этой сессии.' 'Закройте окно и запустите УСТАНОВКА.bat ещё раз — Git уже подхватится.'
    }
}

# ============================================================================
#  Шаг 3 — Python + библиотеки воркера
# ============================================================================
function Step-Python {
    Head 'Шаг 3. Python и библиотеки (Pillow, openpyxl)'

    $py = Get-PyCmd
    if (-not $py) {
        if (-not $script:OnWindows) { Note '(проверка) python не найден; на Windows выполнил бы: winget install --id Python.Python.3.12'; return }
        if ($DryRun)                { Note '(проверка) winget install --id Python.Python.3.12'; return }
        Install-Winget 'Python.Python.3.12' 'Python 3.12'
        Update-Path
        $py = Get-PyCmd
        if (-not $py) {
            Stop-Install 'Python установился, но не виден в этой сессии.' 'Закройте окно и запустите УСТАНОВКА.bat ещё раз.'
        }
    }
    Ok "Python найден: $py"

    if ($DryRun) { Note "(проверка) $py -m pip install --upgrade Pillow openpyxl"; return }

    if (Test-PyImport $py) { Ok 'Pillow и openpyxl уже стоят'; return }

    Note 'Ставлю Pillow и openpyxl (сжатие картинок в WebP и чтение раскадровки XLSX)...'
    & $py -m pip install --upgrade Pillow openpyxl
    if (-not (Test-PyImport $py)) {
        Note 'Пробую поставить в профиль пользователя (--user)...'
        & $py -m pip install --upgrade --user Pillow openpyxl
    }
    if (Test-PyImport $py) {
        Ok 'Pillow и openpyxl готовы'
    } else {
        Warn 'Не удалось поставить библиотеки автоматически.'
        $script:attn.Add('Открыть командную строку и выполнить: py -m pip install Pillow openpyxl')
    }
}

# ============================================================================
#  Шаг 4 — проект (клон или обновление) + подпись коммитов воркера
# ============================================================================
function Step-Project {
    Head "Шаг 4. Проект: $script:Root"

    if (-not (Get-Command git -ErrorAction SilentlyContinue) -and -not $DryRun) {
        Stop-Install 'Git недоступен — не могу скачать проект.' 'Вернитесь к шагу 2.'
    }

    $gitDir = Join-Path $script:Root '.git'

    if (Test-Path $gitDir) {
        # Репозиторий уже есть — обновляем.
        Ok 'проект уже на месте (git-репозиторий найден)'
        if ($DryRun) {
            Note '(проверка) git -C <проект> pull --ff-only'
        } else {
            Note 'Обновляю проект (git pull)...'
            & git -C $script:Root pull --ff-only 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Ok 'проект обновлён' }
            else { Warn 'Обновить не удалось (возможно, есть несохранённые изменения воркера). Установке это не мешает.' }
        }
    }
    elseif ((Test-Path $script:Root) -and (@(Get-ChildItem -Force -LiteralPath $script:Root -ErrorAction SilentlyContinue).Count -gt 0)) {
        # Папка есть, но это не git-репозиторий (например, распакованный ZIP).
        $looksOurs = (Test-Path (Join-Path $script:Root 'ВОРКЕР.md')) -or (Test-Path (Join-Path $script:Root 'УСТАНОВКА.bat'))
        if ($looksOurs) {
            if ($DryRun) {
                Note '(проверка) папка без git — привязал бы её к репозиторию: git init + remote add + fetch + reset --mixed origin/main'
            } else {
                Note 'Папка есть, но без git — привязываю её к репозиторию без потери файлов...'
                & git -C $script:Root init -b main 2>&1 | Out-Null
                & git -C $script:Root remote remove origin 2>$null
                & git -C $script:Root remote add origin $script:RepoUrl 2>&1 | Out-Null
                & git -C $script:Root fetch origin 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { Stop-Install 'Не удалось скачать данные репозитория.' 'Проверьте интернет и запустите снова.' }
                & git -C $script:Root reset --mixed origin/main 2>&1 | Out-Null
                & git -C $script:Root branch --set-upstream-to=origin/main main 2>$null | Out-Null
                Ok 'папка привязана к репозиторию'
            }
        } else {
            Stop-Install "Папка $script:Root уже существует и это не наш проект." `
                'Переименуйте или удалите её и запустите снова — либо запускайте установщик из другой папки (например, из Загрузок).'
        }
    }
    else {
        # Папки нет или она пустая — клонируем.
        if ($DryRun) {
            Note "(проверка) git clone $script:RepoUrl <проект>"
        } else {
            Note 'Скачиваю проект (git clone)...'
            & git clone $script:RepoUrl $script:Root
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $gitDir)) {
                Stop-Install 'Не удалось скачать проект.' 'Проверьте интернет и запустите установку снова.'
            }
            Ok 'проект скачан'
        }
    }

    # Подпись коммитов воркера — локально в репозитории, глобальные настройки не трогаем.
    if ($DryRun) {
        Note '(проверка) git config user.name «Воркер», user.email noreply@amintako.local (локально)'
    } elseif (Test-Path $gitDir) {
        & git -C $script:Root config user.name  'Воркер' 2>$null
        & git -C $script:Root config user.email 'noreply@amintako.local' 2>$null
        Ok 'подпись коммитов воркера настроена'
    }
}

# ============================================================================
#  Шаг 5 — файл ключей .env
# ============================================================================
function Step-Env {
    Head 'Шаг 5. Файл ключей .env'

    $dest = Join-Path $script:Root '.env'
    $installerDir = Split-Path $PSScriptRoot -Parent      # папка, где лежит УСТАНОВКА.bat
    $src  = Join-Path $installerDir '.env'                # .env, который передал Иса рядом с установщиком

    $srcFull  = try { (Resolve-Path -LiteralPath $src  -ErrorAction Stop).Path } catch { $null }
    $destFull = try { (Resolve-Path -LiteralPath $dest -ErrorAction Stop).Path } catch { $null }
    $sameFile = ($srcFull -and $destFull -and ($srcFull -eq $destFull))

    if ($srcFull -and -not $sameFile) {
        # Рядом с установщиком лежит .env — это источник правды, копируем в проект.
        if ($DryRun) {
            Note '(проверка) копирую .env из папки установщика в проект'
        } elseif (Test-Path $script:Root) {
            Copy-Item -LiteralPath $src -Destination $dest -Force
            Ok 'файл .env скопирован в проект'
        }
    }
    elseif (Test-Path $dest) {
        Ok '.env уже есть в проекте'
    }
    else {
        # .env нет нигде — создаём заготовку с тремя пустыми полями.
        # ВАЖНО: без BOM, иначе воркер прочитает первый ключ как «﻿SUPABASE_URL».
        if ($DryRun) {
            Note '(проверка) создаю заготовку .env с пустыми ключами (SUPABASE_URL, SUPABASE_SECRET_KEY, GITHUB_TOKEN)'
        } elseif (Test-Path $script:Root) {
            $stub = "# Файл ключей конвейера «АминТако».`r`n" +
                    "# Заполните значения (их даёт Иса) и сохраните файл. Без них конвейер не запустится.`r`n`r`n" +
                    "SUPABASE_URL=`r`nSUPABASE_SECRET_KEY=`r`nGITHUB_TOKEN=`r`n"
            [System.IO.File]::WriteAllText($dest, $stub, (New-Object System.Text.UTF8Encoding($false)))
            Warn 'Создал пустую заготовку .env — ключей в ней пока нет.'
        }
    }

    # Разбираем .env и проверяем, все ли нужные ключи заполнены.
    if (Test-Path $dest) { $script:cfg = Read-DotEnv $dest }

    $missing = @()
    foreach ($k in @('SUPABASE_URL', 'SUPABASE_SECRET_KEY', 'GITHUB_TOKEN')) {
        if (-not $script:cfg.ContainsKey($k) -or [string]::IsNullOrWhiteSpace($script:cfg[$k])) { $missing += $k }
    }
    if ($missing.Count -eq 0) {
        Ok 'ключи на месте: SUPABASE_URL, SUPABASE_SECRET_KEY, GITHUB_TOKEN'
    } else {
        Warn ('В .env не заполнено: ' + ($missing -join ', '))
        $script:attn.Add('Заполнить в .env (' + ($missing -join ', ') + ') — ключи у Исы. Файл: ' + $dest)
    }
}

# ============================================================================
#  Шаг 6 — доступ на отправку кадров (git push по токену)
# ============================================================================
function Step-Push {
    Head 'Шаг 6. Доступ на отправку кадров (git push)'

    $token = if ($script:cfg.ContainsKey('GITHUB_TOKEN')) { $script:cfg['GITHUB_TOKEN'] } else { '' }

    if ([string]::IsNullOrWhiteSpace($token)) {
        Warn 'GITHUB_TOKEN не задан — автоматическая отправка кадров не настроена.'
        $script:attn.Add('Добавить GITHUB_TOKEN в .env и запустить установщик снова — тогда включится автопуш.')
        return
    }
    if ($DryRun) {
        Note '(проверка) настрою remote с токеном (в вывод токен не попадёт) и проверю запись через git push --dry-run'
        return
    }
    if (-not (Test-Path (Join-Path $script:Root '.git'))) { Warn 'Нет репозитория — пропускаю.'; return }

    # Токен зашиваем в адрес origin: воркер пушит без ввода логина/пароля.
    # Адрес с токеном лежит локально в .git/config и в репозиторий не уходит.
    $pushUrl = "https://x-access-token:$token@github.com/$script:RepoSlug.git"
    & git -C $script:Root remote set-url origin $pushUrl 2>$null
    if ($LASTEXITCODE -ne 0) { & git -C $script:Root remote add origin $pushUrl 2>$null }
    # Никаких менеджеров паролей для этого репозитория — только токен из адреса,
    # чтобы при протухшем токене не всплывало окно логина (воркер тогда зовёт человека).
    & git -C $script:Root config --local credential.helper '' 2>$null
    Ok 'адрес отправки настроен (токен сохранён локально, в выводе не показан)'

    Note 'Проверяю право записи (git push --dry-run)...'
    $raw  = & git -C $script:Root push --dry-run origin HEAD 2>&1
    $code = $LASTEXITCODE
    $safe = ("$($raw | Out-String)").Replace($token, '***')     # на всякий случай вычищаем токен из вывода

    if ($code -eq 0) {
        Ok 'право на запись подтверждено — GitHub принимает отправку'
    } else {
        if ($safe -match '403|401|Authentication|denied|could not read Username') {
            Warn 'GitHub не принял токен для записи (нет прав или токен протух).'
            $script:attn.Add("Проверить GITHUB_TOKEN у Исы — GitHub отклонил отправку (нужны права contents:write на $script:RepoSlug).")
        } else {
            Warn 'Проверка отправки не прошла. Ответ GitHub — ниже.'
            $script:attn.Add('Проверить доступ к GitHub — git push --dry-run не прошёл.')
        }
        if ($safe.Trim()) { Write-Host "    $($safe.Trim())" -ForegroundColor DarkGray }
    }
}

# ============================================================================
#  Шаг 7 — связь с базой Supabase
# ============================================================================
function Step-Supabase {
    Head 'Шаг 7. Связь с базой (Supabase)'

    $url = if ($script:cfg.ContainsKey('SUPABASE_URL'))        { $script:cfg['SUPABASE_URL'].TrimEnd('/') } else { '' }
    $key = if ($script:cfg.ContainsKey('SUPABASE_SECRET_KEY')) { $script:cfg['SUPABASE_SECRET_KEY'] }        else { '' }

    if ([string]::IsNullOrWhiteSpace($url) -or [string]::IsNullOrWhiteSpace($key)) {
        Warn 'Нет SUPABASE_URL или SUPABASE_SECRET_KEY — пропускаю проверку базы.'
        return
    }
    if ($DryRun) { Note "(проверка) GET $url/rest/v1/series — покажу число серий"; return }

    try {
        $headers = @{ apikey = $key; Authorization = "Bearer $key" }   # ключ в консоль не печатается
        $resp = Invoke-RestMethod -Uri "$url/rest/v1/series?select=id,number,title&order=id" `
                    -Headers $headers -TimeoutSec 25 -Method Get -ErrorAction Stop
        Ok ("база отвечает, серий: {0}" -f @($resp).Count)
    } catch {
        Warn ('База не ответила: ' + $_.Exception.Message)
        $script:attn.Add('Проверить SUPABASE_URL / SUPABASE_SECRET_KEY или интернет — база не ответила.')
    }
}

# ============================================================================
#  Шаг 8 — ярлык «Chrome — Воркер» на рабочем столе
# ============================================================================
function Step-Chrome {
    Head 'Шаг 8. Ярлык «Chrome — Воркер»'

    if (-not $script:OnWindows) {
        Note "(проверка) на Windows нашёл бы chrome.exe и создал бы ярлык с профилем `"$script:ProfileDir`""
        return
    }

    $chrome = Find-Chrome
    if (-not $chrome) {
        if ($DryRun) {
            Note '(проверка) Chrome не найден; выполнил бы: winget install --id Google.Chrome'
        } else {
            Note 'Chrome не найден — устанавливаю...'
            Install-Winget 'Google.Chrome' 'Google Chrome'
            Update-Path
            $chrome = Find-Chrome
        }
    } else {
        Note "Chrome найден: $chrome"
    }

    if ($DryRun) {
        Note "(проверка) создам ярлык «Chrome — Воркер» → chrome.exe --profile-directory=`"$script:ProfileDir`""
        return
    }
    if (-not $chrome) {
        Warn 'Chrome не установился — ярлык не создан.'
        $script:attn.Add('Установить Google Chrome и создать профиль воркера вручную.')
        return
    }

    try {
        $desktop = [Environment]::GetFolderPath('Desktop')          # учитывает кириллицу и OneDrive
        $lnk = Join-Path $desktop 'Chrome — Воркер.lnk'
        $wsh = New-Object -ComObject WScript.Shell
        $sc  = $wsh.CreateShortcut($lnk)
        $sc.TargetPath       = $chrome
        $sc.Arguments        = "--profile-directory=`"$script:ProfileDir`""
        $sc.WorkingDirectory = Split-Path $chrome -Parent
        $sc.IconLocation     = "$chrome,0"
        $sc.Description       = 'Chrome для конвейера АминТако (профиль воркера)'
        $sc.Save()
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wsh)
        Ok 'ярлык «Chrome — Воркер» на рабочем столе готов'
    } catch {
        Warn ('Не удалось создать ярлык: ' + $_.Exception.Message)
        $script:attn.Add("Создать ярлык Chrome с параметром --profile-directory=`"$script:ProfileDir`" вручную.")
    }
}

# ============================================================================
#  Шаг 9 — чтобы компьютер не засыпал
# ============================================================================
function Step-Power {
    Head 'Шаг 9. Чтобы компьютер не засыпал'

    if (-not $script:OnWindows) {
        Note '(проверка) на Windows выполнил бы: powercfg /change standby-timeout-ac 0 и hibernate-timeout-ac 0'
        return
    }
    if ($DryRun) {
        Note '(проверка) powercfg /change standby-timeout-ac 0; powercfg /change hibernate-timeout-ac 0'
        Note 'Ноутбук: крышку всё равно закрывать нельзя — от этого он уснёт.'
        return
    }

    $ok = $true
    & powercfg /change standby-timeout-ac   0 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { $ok = $false }
    & powercfg /change hibernate-timeout-ac 0 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { $ok = $false }
    if ($ok) {
        Ok 'компьютер не будет засыпать от простоя (при питании от сети)'
    } else {
        Warn 'Не удалось изменить питание автоматически.'
        $script:attn.Add('Поставить спящий режим «Никогда»: Параметры → Система → Питание.')
    }
    Note 'Ноутбук: крышку всё равно закрывать нельзя — от этого он уснёт.'
}

# ============================================================================
#  Шаг 10 — итоговая сводка
# ============================================================================
function Step-Summary {
    Head 'Готово. Что осталось сделать руками'

    Write-Host ''
    Write-Host "  Проект установлен в: $script:Root" -ForegroundColor White
    Write-Host ''
    Write-Host '  Это может сделать только человек — логины и подтверждения:' -ForegroundColor Cyan

    $manual = @(
        'Откройте ярлык «Chrome — Воркер» на рабочем столе и войдите в chatgpt.com и labs.google (логины даст Иса). Закройте и снова откройте — проверьте, что вход сохранился.',
        "В приложении Claude добавьте папку $script:Root в доверенные (Cowork / trusted folders).",
        'Первый запуск воркера сделайте рядом с человеком: самый первый git push нужно подтвердить один раз.'
    )
    $i = 1
    foreach ($m in $manual) { Write-Host ("   {0}. {1}" -f $i, $m) -ForegroundColor White; $i++ }

    if ($script:attn.Count -gt 0) {
        Write-Host ''
        Write-Host '  Внимание (без этого конвейер не заработает полностью):' -ForegroundColor Yellow
        foreach ($a in $script:attn) { Write-Host "   ! $a" -ForegroundColor Yellow }
    }

    Write-Host ''
    if ($DryRun) { Write-Host '  Это был режим проверки — ничего не менялось.' -ForegroundColor Yellow }
    else         { Write-Host '  Установка завершена.' -ForegroundColor Green }
}

# ============================================================================
#  Главный ход
# ============================================================================
Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host '  Установка конвейера кадров «АминТако»' -ForegroundColor Cyan
Write-Host '  Подготовка компьютера воркера — один запуск' -ForegroundColor Cyan
if ($DryRun) { Write-Host '  РЕЖИМ ПРОВЕРКИ: ничего не меняется, только показ шагов' -ForegroundColor Yellow }
Write-Host '═══════════════════════════════════════════════════════════' -ForegroundColor Cyan

try {
    Step-Environment
    Step-Git
    Step-Python
    Step-Project
    Step-Env
    Step-Push
    Step-Supabase
    Step-Chrome
    Step-Power
    Step-Summary
} catch {
    Write-Host ''
    Write-Host ('  × Непредвиденная ошибка: ' + $_.Exception.Message) -ForegroundColor Red
    if ($_.ScriptStackTrace) { Write-Host ('    ' + ($_.ScriptStackTrace -split "`n")[0]) -ForegroundColor DarkGray }
    Write-Host '  Сделайте скриншот этого окна и пришлите Исе.' -ForegroundColor Yellow
    exit 1
}
exit 0
