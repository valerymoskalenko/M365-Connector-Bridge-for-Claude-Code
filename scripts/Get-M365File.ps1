<#
.SYNOPSIS
  Read a SharePoint / OneDrive file or folder as the target account, by its URL: details, folder list,
  download, or the file as text. The bridge's equivalent of the claude.ai connector's read_resource for files.

.DESCRIPTION
  READ-ONLY. Through Invoke-M365SharePoint.ps1 (SharePoint connection):
    _api/v2.0/shares/u!<base64url of the URL>/driveItem   -> the item behind any URL the account can open
  Accepted URLs: a file / folder / library URL (as Search-M365Files.ps1 or the browser shows it, with or
  without %20), a sharing link (https://<host>/:w:/s/..., /:x:/g/personal/...), an "/:w:/r/..." link, an
  Office web link (.../_layouts/15/Doc.aspx?sourcedoc={guid}&file=...), a OneDrive URL of the account or of
  someone who shared with it. A bare site URL has no item: use -Libraries.

  Download: the item's @content.downloadUrl (short-lived, pre-authenticated) is fetched straight from
  SharePoint - no 4 MB connector limit. The script never prints that URL: anyone holding it can download
  the file until it expires.

  -Text converts the file with markitdown (Python 3.11+: py -m pip install "markitdown[all]"): docx, xlsx,
  xls, pptx, pdf, msg, rtf, html. Plain-text types (txt, md, csv, json, xml, ...) are read as they are.
  Old .doc / .ppt are first saved as .docx / .pptx by the local Word / PowerPoint (Windows; read-only,
  macros forced off). Not readable as text: .vsdx, .potx / .dotx templates, archives.
  -Pages renders PDF pages to PNG (PyMuPDF: py -m pip install pymupdf) for a PDF made of pictures; Claude
  then reads the PNG files (its own PDF reading needs poppler / pdftoppm, which may be missing).
  Python runs with -E -P: nothing is loaded from the download folder or the current folder.

.PARAMETER Url
  The file, folder or library URL, sharing link, or site URL (with -Libraries).
.PARAMETER Libraries
  List the document libraries of the site in -Url.
.PARAMETER OutFile
  Download the file to this path.
.PARAMETER OutDir
  Download the file into this folder (keeps the file name). Default for -Text: <temp>\m365-bridge-files.
.PARAMETER Text
  Download and print the file as text (Markdown). Also saves <file>.md next to the download.
.PARAMETER MaxChars
  -Text prints at most this many characters (default 60000); the full text stays in the .md file.
.PARAMETER Pages
  Download a PDF and render pages -FirstPage..-LastPage (default 1-20) to PNG files in <file>-pages; prints their paths.
.PARAMETER MaxSizeMB
  Refuse downloads larger than this (default 200).
.PARAMETER Raw
  Return PowerShell objects instead of JSON text.

.EXAMPLE
  .\Get-M365File.ps1 'https://contoso.sharepoint.com/sites/Marketing/Shared Documents/Plan.docx' -Text
.EXAMPLE
  .\Get-M365File.ps1 'https://contoso.sharepoint.com/sites/Marketing/Shared Documents/Campaigns'
.EXAMPLE
  .\Get-M365File.ps1 'https://contoso.sharepoint.com/:x:/s/Marketing/EaBcDeF...' -OutDir C:\Temp
.EXAMPLE
  .\Get-M365File.ps1 'https://contoso.sharepoint.com/sites/Marketing' -Libraries
#>
[CmdletBinding(DefaultParameterSetName = 'Info')]
param(
    [Parameter(Mandatory, Position = 0)][string]$Url,
    [Parameter(Mandatory, ParameterSetName = 'Libraries')][switch]$Libraries,
    [Parameter(ParameterSetName = 'Download')][string]$OutFile,
    [Parameter(ParameterSetName = 'Download')][Parameter(ParameterSetName = 'Text')][Parameter(ParameterSetName = 'Pages')][string]$OutDir,
    [Parameter(Mandatory, ParameterSetName = 'Text')][switch]$Text,
    [Parameter(ParameterSetName = 'Text')][int]$MaxChars = 60000,
    [Parameter(Mandatory, ParameterSetName = 'Pages')][switch]$Pages,
    [Parameter(ParameterSetName = 'Pages')][int]$FirstPage = 1,
    [Parameter(ParameterSetName = 'Pages')][int]$LastPage = 20,
    [int]$MaxSizeMB = 200,
    [switch]$Raw
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$sp = Join-Path $PSScriptRoot 'Invoke-M365SharePoint.ps1'

function Out-Result($o) { if ($Raw) { return $o } ; ConvertTo-Json @($o) -Depth 6 }
function ConvertTo-ShareId([string]$u) { 'u!' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($u)).TrimEnd('=').Replace('/', '_').Replace('+', '-') }
function Get-Host([string]$u) { ([uri]$u).GetLeftPart([UriPartial]::Authority) }
function ConvertTo-Utc($v) {
    if ($null -eq $v -or "$v" -eq '') { return $null }
    if ($v -is [datetime]) { return $v.ToUniversalTime() }    # Invoke-RestMethod may already have parsed the ISO text
    return ([datetimeoffset]::Parse("$v", [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime
}
# Python for markitdown / PyMuPDF. -E -P (3.11+): no PYTHON* variables, nothing loaded from the download folder or the
# current folder, but user-installed packages stay visible (-I hides them). Older Python: -I.
function Invoke-Python([string[]]$PyArgs) {
    if (-not $script:pyCmd) {
        $script:pyCmd = @('py', 'python3', 'python') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
        if (-not $script:pyCmd) { throw 'No Python found (py, python3, python). Install Python 3.11+.' }
        $v = & $script:pyCmd -c 'import sys; print(sys.version_info >= (3, 11))' 2>$null
        $script:pyFlags = if ("$v".Trim() -eq 'True') { @('-E', '-P', '-X', 'utf8') } else { @('-I', '-X', 'utf8') }
    }
    $o = & $script:pyCmd @script:pyFlags @PyArgs 2>&1
    return [pscustomobject]@{ Exit = $LASTEXITCODE; Output = @($o | ForEach-Object { "$_" }) }
}

# .doc / .ppt (old binary formats, markitdown can't read them): convert to .docx / .pptx with the local Word /
# PowerPoint (Windows), read-only, macros forced off. Office is quit only if it has no other open files.
function Convert-OldOffice([string]$path, [string]$ext) {
    if (-not $IsWindows) { throw "markitdown can't read .$ext, and Word / PowerPoint conversion needs Windows. The file is saved: $path" }
    $full = (Resolve-Path -LiteralPath $path).ProviderPath
    $new = $full + 'x'
    if ($ext -eq 'doc') {
        try { $app = New-Object -ComObject Word.Application } catch { throw "markitdown can't read .doc and Word is not installed. The file is saved: $full" }
        try {
            $app.Visible = $false; $app.DisplayAlerts = 0; $app.AutomationSecurity = 3    # msoAutomationSecurityForceDisable
            $d = $app.Documents.Open($full, $false, $true, $false)                       # ConfirmConversions, ReadOnly, AddToRecentFiles
            $d.SaveAs2($new, 16); $d.Close($false)                                       # wdFormatDocumentDefault (.docx)
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($d)
        }
        finally { if ($app.Documents.Count -eq 0) { $app.Quit() }; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($app); [GC]::Collect(); [GC]::WaitForPendingFinalizers() }
    }
    else {
        try { $app = New-Object -ComObject PowerPoint.Application } catch { throw "markitdown can't read .ppt and PowerPoint is not installed. The file is saved: $full" }
        try {
            $app.AutomationSecurity = 3
            $p = $app.Presentations.Open($full, -1, 0, 0)                                  # ReadOnly, Untitled = no, WithWindow = no
            $p.SaveAs($new, 24); $p.Close()                                                # ppSaveAsOpenXMLPresentation (.pptx)
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($p)
        }
        finally { if ($app.Presentations.Count -eq 0) { $app.Quit() }; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($app); [GC]::Collect(); [GC]::WaitForPendingFinalizers() }
    }
    return $new
}

function Get-ItemType($i) { if ($i.folder) { 'folder' } elseif ($i.name -match '\.([^.]+)$') { $Matches[1].ToLower() } else { 'file' } }
function ConvertTo-ItemInfo($i) {
    [pscustomobject][ordered]@{
        Name       = $i.name
        Type       = Get-ItemType $i
        Size       = if ($i.folder) { $null } else { $i.size }
        Children   = if ($i.folder) { $i.folder.childCount } else { $null }
        Modified   = ConvertTo-Utc $i.lastModifiedDateTime
        ModifiedBy = $i.lastModifiedBy.user.displayName
        Url        = $i.webUrl
    }
}

$Url = $Url.Trim().Trim('<', '>', '"')
if ($Url -notmatch '^https://[^/]+\.sharepoint\.(com|us|de|cn)/') { throw "Not a SharePoint / OneDrive URL: $Url" }

# ---------------------------------------------------------------- site libraries
if ($Libraries) {
    $site = ($Url -split '\?')[0].TrimEnd('/')
    $d = & $sp '_api/v2.0/drives?$select=id,name,webUrl,driveType,lastModifiedDateTime' -Site $site -All -Raw
    return Out-Result @($d | ForEach-Object { [pscustomobject][ordered]@{ Name = $_.name; Url = $_.webUrl; Modified = ConvertTo-Utc $_.lastModifiedDateTime } })
}

# ---------------------------------------------------------------- resolve the URL to a driveItem
$select = 'id,name,size,webUrl,file,folder,lastModifiedDateTime,lastModifiedBy,parentReference'
function Get-DriveItem([string]$u, [switch]$WithDownloadUrl) {
    $sel = if ($WithDownloadUrl) { "$select,@content.downloadUrl" } else { $select }
    & $sp "_api/v2.0/shares/$(ConvertTo-ShareId $u)/driveItem?`$select=$sel" -Site (Get-Host $u) -Raw
}
function Resolve-Url([string]$u) {
    # /:w:/r/<path>?... = a plain path behind a redirect prefix
    if ($u -match '^(https://[^/]+)/:[a-z]:/r/([^?]+)') { return "$($Matches[1])/$($Matches[2])" }
    # Office web link: .../_layouts/15/Doc.aspx?sourcedoc={guid}&file=...  -> the file's own URL
    if ($u -match '^(https://[^?]+?)/_layouts/15/[^?]+\?(.*)$' -and $Matches[2] -match '(?:^|&)sourcedoc=([^&]+)') {
        $siteUrl = ($u -replace '/_layouts/15/.*$', '')
        $guid = [uri]::UnescapeDataString($Matches[1]).Trim('{', '}')
        $f = & $sp "_api/web/GetFileById('$guid')?`$select=ServerRelativeUrl" -Site $siteUrl -Raw
        return "$(Get-Host $siteUrl)$($f.ServerRelativeUrl)"
    }
    return $u
}
$target = Resolve-Url $Url
$wantDownload = $Text -or $Pages -or $OutFile -or $OutDir
$item = Get-DriveItem $target -WithDownloadUrl:$wantDownload

# ---------------------------------------------------------------- folder: list its children
if ($item.folder) {
    if ($wantDownload) { throw "$($item.name) is a folder: download its files one by one." }
    $driveId = $item.parentReference.driveId
    $kids = & $sp "_api/v2.0/drives/$driveId/items/$($item.id)/children?`$select=$select&`$top=200" -Site (Get-Host $target) -All -MaxPages 25 -Raw
    $list = @($kids | ForEach-Object { ConvertTo-ItemInfo $_ } | Sort-Object @{ e = { $_.Type -ne 'folder' } }, Name)
    $label = if ($item.name -eq 'root' -and $item.webUrl) { [uri]::UnescapeDataString(($item.webUrl.TrimEnd('/') -split '/')[-1]) } else { $item.name }   # a library's root folder is called "root"
    Write-Host "$($label): $(@($list | Where-Object Type -eq 'folder').Count) folder(s), $(@($list | Where-Object Type -ne 'folder').Count) file(s)"
    return Out-Result $list
}

$info = ConvertTo-ItemInfo $item
if (-not $wantDownload) { return Out-Result $info }
if ($Pages -and $info.Type -ne 'pdf') { throw "-Pages is for PDF files; $($item.name) is .$($info.Type). Use -Text." }

# ---------------------------------------------------------------- download (straight from SharePoint, pre-authenticated URL)
$dl = $item.'@content.downloadUrl'
if (-not $dl) { throw "SharePoint gave no download URL for $($item.name) (the account may only view it, or it is not a file)." }
if ($item.size -gt $MaxSizeMB * 1MB) { throw "$($item.name) is $([math]::Round($item.size / 1MB, 1)) MB, over -MaxSizeMB $MaxSizeMB." }
$safeName = ($item.name -replace '[\\/:*?"<>|]', '_')
if (-not $OutFile) {
    if (-not $OutDir) { $OutDir = Join-Path ([IO.Path]::GetTempPath()) 'm365-bridge-files' }
    $OutFile = Join-Path $OutDir $safeName
}
$dir = Split-Path $OutFile -Parent; if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri $dl -OutFile $OutFile -UseBasicParsing
$dl = $null
$len = (Get-Item $OutFile).Length
if (-not $Text -and -not $Pages) { Write-Host "Saved $len bytes to $OutFile"; return Out-Result $info }
$ext = [IO.Path]::GetExtension($OutFile).TrimStart('.').ToLower()

# ---------------------------------------------------------------- PDF pages as PNG (PDF made of pictures)
if ($Pages) {
    $pngDir = "$OutFile-pages"
    $r = Invoke-Python @((Join-Path $PSScriptRoot 'Convert-PdfToPng.py'), $OutFile, $pngDir, "$FirstPage", "$LastPage")
    if ($r.Exit -ne 0) {
        $msg = ($r.Output -join "`n") -replace '(?s)^(.{600}).*', '$1...'
        $hint = if ($msg -match "No module named 'pymupdf'") { "`nInstall PyMuPDF: py -m pip install pymupdf" } else { '' }
        throw "Could not render $OutFile (exit $($r.Exit)): $msg$hint"
    }
    $pngs = @($r.Output | Where-Object { $_ -match '\.png$' })
    $range = @($r.Output | Where-Object { $_ -match '^pages ' })
    Write-Host "$($item.name): $($range -join ' '), saved as PNG in $pngDir. Read the PNG files."
    if ($Raw) { return [pscustomobject]@{ Info = $info; File = $OutFile; PageImages = $pngs } }
    return $pngs
}

# ---------------------------------------------------------------- as text
$plain = 'txt', 'md', 'csv', 'tsv', 'json', 'xml', 'yml', 'yaml', 'log', 'ps1', 'py', 'js', 'ts', 'cs', 'sql', 'al', 'ini', 'css'
$md = "$OutFile.md"
if ($ext -in $plain) { $body = [IO.File]::ReadAllText($OutFile) }
else {
    $src = if ($ext -in 'doc', 'ppt') { Convert-OldOffice $OutFile $ext } else { $OutFile }
    $r = Invoke-Python @('-m', 'markitdown', $src, '-o', $md)
    if ($r.Exit -ne 0 -or -not (Test-Path $md)) {
        $msg = ($r.Output -join "`n").Trim()
        $why = if ($msg -match 'No module named markitdown') { "markitdown is not installed: py -m pip install `"markitdown[all]`"" }
               elseif ($msg -match 'UnsupportedFormatException|FileConversionException') { "markitdown can't read .$ext files" }
               else { $msg -replace '(?s)^(.{600}).*', '$1...' }
        throw "No text from $OutFile - $why. The file itself is saved."
    }
    $body = [IO.File]::ReadAllText($md)
}
if ($ext -in $plain) { [IO.File]::WriteAllText($md, $body) }
$note = "# $($item.name)`n$($info.Type), $len bytes, modified $($info.Modified.ToString('yyyy-MM-dd HH:mm')) UTC by $($info.ModifiedBy)`nSaved: $OutFile (text: $md)`n"
if ($ext -eq 'pdf' -and $body.Length -lt [math]::Max(300, 2000 * $len / 1MB)) { $note += "Little text for the file size: the PDF is probably made of pictures. Run again with -Pages and read the PNG files.`n" }
if ($body.Length -gt $MaxChars) { $body = $body.Substring(0, $MaxChars) + "`n`n[... cut at $MaxChars of $($body.Length) characters - full text in $md]" }
if ($Raw) { return [pscustomobject]@{ Info = $info; File = $OutFile; TextFile = $md; Text = $body } }
$note + "`n" + $body
