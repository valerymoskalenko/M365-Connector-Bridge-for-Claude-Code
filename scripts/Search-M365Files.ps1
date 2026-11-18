<#
.SYNOPSIS
  Search files and folders in SharePoint and OneDrive as the target account (SharePoint search, KQL).
  The bridge's equivalent of the claude.ai connector's sharepoint_search / sharepoint_folder_search.

.DESCRIPTION
  Calls _api/search/query through Invoke-M365SharePoint.ps1 (SharePoint connection, read-only).
  Searches every site and every OneDrive the target account can open, and only those: SharePoint search
  trims results to the user's permissions. Words match file names, titles, authors and the text inside
  documents. The index lags a few minutes behind new or changed files.

  Output: one object per hit - Name, Url, Type ("folder" or the extension), Size, Modified (UTC), ModifiedBy,
  Author, Site, Summary (text around the hit). Read a hit with Get-M365File.ps1 <Url>.

.PARAMETER Query
  KQL: words, "exact phrase", AND / OR / NOT, property filters such as filename:report, author:"Jane Doe",
  filetype:docx, LastModifiedTime>=2026-01-01, path:"https://contoso.sharepoint.com/sites/X/Shared Documents/Y".
.PARAMETER Site
  Only results under this URL (a site, library or folder URL; also a OneDrive URL).
.PARAMETER FileType
  Only these extensions (docx, xlsx, pptx, pdf, ...).
.PARAMETER Folders
  Search folders instead of files.
.PARAMETER AnyType
  No file / folder filter (also pages, list items, sites).
.PARAMETER ModifiedAfter
  Only items changed on or after this date.
.PARAMETER Top
  Results per call (default 25, max 500).
.PARAMETER Skip
  Start at this result (paging).
.PARAMETER SortBy
  Relevance (default), Modified (newest first), Size (largest first).
.PARAMETER Raw
  Return PowerShell objects instead of JSON text.

.EXAMPLE
  .\Search-M365Files.ps1 'budget 2027' -FileType xlsx
.EXAMPLE
  .\Search-M365Files.ps1 -Site 'https://contoso.sharepoint.com/sites/Marketing' -SortBy Modified -Top 10
.EXAMPLE
  .\Search-M365Files.ps1 'logo' -Folders
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Query,
    [string]$Site,
    [string[]]$FileType,
    [switch]$Folders,
    [switch]$AnyType,
    [datetime]$ModifiedAfter,
    [ValidateRange(1, 500)][int]$Top = 25,
    [ValidateRange(0, 50000)][int]$Skip = 0,
    [ValidateSet('Relevance', 'Modified', 'Size')][string]$SortBy = 'Relevance',
    [switch]$Raw
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$sp = Join-Path $PSScriptRoot 'Invoke-M365SharePoint.ps1'

$kql = [Collections.Generic.List[string]]::new()
if ($Query) { $kql.Add($Query) }
if ($Site) { $kql.Add("path:`"$([uri]::UnescapeDataString($Site.TrimEnd('/')))`"") }
if ($FileType) { $kql.Add('(' + ((@($FileType) | ForEach-Object { "filetype:$($_.TrimStart('.'))" }) -join ' OR ') + ')') }
# folders: without the contentclass filter the site itself counts as a "container" too
if ($Folders) { $kql.Add('IsContainer:true (contentclass:STS_ListItem_DocumentLibrary OR contentclass:STS_ListItem_MySiteDocumentLibrary)') }
elseif (-not $AnyType) { $kql.Add('IsDocument:true') }
if ($PSBoundParameters.ContainsKey('ModifiedAfter')) { $kql.Add("LastModifiedTime>=$($ModifiedAfter.ToString('yyyy-MM-dd'))") }
if (-not $Query -and -not $Site -and -not $FileType -and -not $PSBoundParameters.ContainsKey('ModifiedAfter')) { throw 'Give a -Query, -Site, -FileType or -ModifiedAfter.' }

# REST string literal: ' -> '' ; then URL-encode (&, #, + in names)
$q = [uri]::EscapeDataString(($kql -join ' ').Replace("'", "''"))
$props = 'Title,Filename,Path,FileType,IsContainer,Size,LastModifiedTime,ModifiedBy,Author,SPSiteUrl,HitHighlightedSummary'
$uri = "_api/search/query?querytext='$q'&rowlimit=$Top&startrow=$Skip&selectproperties='$props'&clienttype='ContentSearchRegular'"
switch ($SortBy) {
    'Modified' { $uri += "&sortlist='LastModifiedTime:descending'" }
    'Size' { $uri += "&sortlist='Size:descending'" }
}

Write-Verbose "KQL: $($kql -join ' ')"
Write-Verbose "GET $uri"
$r = & $sp $uri -Raw
$rel = $r.PrimaryQueryResult.RelevantResults
$hits = foreach ($row in @($rel.Table.Rows)) {
    $h = @{}; foreach ($c in $row.Cells) { $h[$c.Key] = $c.Value }
    $isFolder = "$($h.IsContainer)" -eq 'true'
    $summary = "$($h.HitHighlightedSummary)" -replace '<ddd/>', ' ... ' -replace '</?c\d+>', '' -replace '\s+', ' '
    $modified = $null   # Invoke-RestMethod may already have turned the ISO text into [datetime]
    if ($h.LastModifiedTime -is [datetime]) { $modified = $h.LastModifiedTime.ToUniversalTime() }
    elseif ($h.LastModifiedTime) { $modified = ([datetimeoffset]::Parse($h.LastModifiedTime, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime }
    [pscustomobject][ordered]@{
        Name       = if ($h.Filename) { $h.Filename } else { $h.Title }
        Url        = $h.Path
        Type       = if ($isFolder) { 'folder' } else { $h.FileType }
        Size       = if ($isFolder -or -not $h.Size) { $null } else { [long]$h.Size }
        Modified   = $modified
        ModifiedBy = $h.ModifiedBy
        Author     = $h.Author
        Site       = $h.SPSiteUrl
        Summary    = $summary.Trim()
    }
}
$total = [int]$rel.TotalRows
$shown = @($hits).Count
Write-Host "Search: $total result(s) (approximate); showing $($Skip + [int]($shown -gt 0))-$($Skip + $shown).$(if ($Skip + $shown -lt $total) { " Next page: -Skip $($Skip + $shown)" })"
if ($Raw) { return $hits }
ConvertTo-Json @($hits) -Depth 5
