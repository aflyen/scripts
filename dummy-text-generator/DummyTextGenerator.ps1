#Requires -Version 7.0

<#
.SYNOPSIS
    Generates dummy article text with coherent structure and playful gibberish.
.DESCRIPTION
    Creates lorem ipsum-style content using curated, real-word sentence pools.
    Supports English and Norwegian, optional title, markdown formatting,
    and simple templates for common demo scenarios.
.PARAMETER Template
    Selects a content template: Custom, Simple, NewsArticle, or Document.
.PARAMETER Language
    Selects sentence language: English (default) or Norwegian.
.PARAMETER ParagraphCount
    Number of body paragraphs for Custom template. Also used as an override
    minimum for NewsArticle and Document templates.
.PARAMETER IncludeTitle
    Adds a concise generated title in Custom template output.
.PARAMETER Markdown
    Formats output using basic markdown (headings and bold preface).
.EXAMPLE
    .\DummyTextGenerator.ps1
.EXAMPLE
    .\DummyTextGenerator.ps1 -Template NewsArticle -Language Norwegian -Markdown
.EXAMPLE
    .\DummyTextGenerator.ps1 -Template Custom -ParagraphCount 4 -IncludeTitle
.NOTES
     Author    : Are Flyen
     Date      : 17.06.2026
.LINK
     https://www.areflyen.no
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('Custom', 'Simple', 'NewsArticle', 'Document')]
    [string]$Template = 'Custom',

    [Parameter()]
    [ValidateSet('English', 'Norwegian')]
    [string]$Language = 'English',

    [Parameter()]
    [ValidateRange(1, 80)]
    [int]$ParagraphCount = 1,

    [Parameter()]
    [switch]$IncludeTitle,

    [Parameter()]
    [switch]$Markdown
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LanguageKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('English', 'Norwegian')]
        [string]$InputLanguage
    )

    switch ($InputLanguage) {
        'English' { 'english' }
        'Norwegian' { 'norwegian' }
        default { throw "Unsupported language: $InputLanguage" }
    }
}

function Get-WordCount {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $tokens = [regex]::Matches($Text, '[A-Za-z0-9]+')
    return $tokens.Count
}

function New-GeneratedTitle {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object[]]$Titles
    )

    $base = $Titles | Get-Random
    $parts = $base -split '\s+'

    # Keep titles concise by selecting at most three words.
    if ($parts.Count -gt 3) {
        $parts = $parts[0..2]
    }

    return ($parts -join ' ').Trim()
}

function New-Paragraph {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object[]]$SentencePool,

        [Parameter(Mandatory)]
        [int]$TargetWordCount,

        [Parameter()]
        [int]$Tolerance = 8
    )

    $paragraphSentences = [System.Collections.Generic.List[string]]::new()
    $usedSentenceIndexes = [System.Collections.Generic.HashSet[int]]::new()
    $safetyCounter = 0
    $maxPoolIndex = $SentencePool.Count

    if ($maxPoolIndex -eq 0) {
        throw 'Sentence pool was empty.'
    }

    while ($true) {
        $index = Get-Random -Minimum 0 -Maximum $maxPoolIndex

        if ($usedSentenceIndexes.Count -lt $maxPoolIndex) {
            while (-not $usedSentenceIndexes.Add($index)) {
                $index = Get-Random -Minimum 0 -Maximum $maxPoolIndex
            }
        }

        $candidate = [string]$SentencePool[$index]
        $paragraphSentences.Add($candidate)
        $joined = ($paragraphSentences -join ' ')
        $wordCount = Get-WordCount -Text $joined

        if ($wordCount -ge ($TargetWordCount - $Tolerance)) {
            break
        }

        $safetyCounter++
        if ($safetyCounter -ge 25) {
            break
        }
    }

    return ($paragraphSentences -join ' ')
}

function New-SectionHeading {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object[]]$SubtitleWords,

        [Parameter(Mandatory)]
        [int]$Index
    )

    $first = $SubtitleWords | Get-Random
    $second = $SubtitleWords | Get-Random

    if ($first -eq $second) {
        $second = $SubtitleWords | Where-Object { $_ -ne $first } | Get-Random
    }

    return "$first $second $Index"
}

function Get-TemplatePlan {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Custom', 'Simple', 'NewsArticle', 'Document')]
        [string]$TemplateName,

        [Parameter(Mandatory)]
        [int]$RequestedParagraphCount
    )

    switch ($TemplateName) {
        'Simple' {
            return @{
                IncludeTitle = $true
                IncludePreface = $false
                Paragraphs = 1
                IncludeSubheadings = $false
                ApproxWords = 95
            }
        }
        'NewsArticle' {
            $paragraphs = [Math]::Max(3, $RequestedParagraphCount)
            return @{
                IncludeTitle = $true
                IncludePreface = $true
                Paragraphs = $paragraphs
                IncludeSubheadings = $true
                ApproxWords = 120
            }
        }
        'Document' {
            # About two pages in common document layout.
            $paragraphs = [Math]::Max(12, $RequestedParagraphCount)
            return @{
                IncludeTitle = $true
                IncludePreface = $false
                Paragraphs = $paragraphs
                IncludeSubheadings = $true
                ApproxWords = 900
            }
        }
        default {
            return @{
                IncludeTitle = [bool]$IncludeTitle
                IncludePreface = $false
                Paragraphs = $RequestedParagraphCount
                IncludeSubheadings = $false
                ApproxWords = [Math]::Max(90, $RequestedParagraphCount * 95)
            }
        }
    }
}

function New-DummyArticleText {
    <#
    .SYNOPSIS
        Creates article-style dummy text from sentence pools.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Custom', 'Simple', 'NewsArticle', 'Document')]
        [string]$TemplateName,

        [Parameter(Mandatory)]
        [ValidateSet('English', 'Norwegian')]
        [string]$InputLanguage,

        [Parameter(Mandatory)]
        [int]$RequestedParagraphCount,

        [Parameter(Mandatory)]
        [bool]$RenderMarkdown,

        [Parameter(Mandatory)]
        [bool]$RequestedTitle
    )

    $scriptPath = $PSScriptRoot
    $sentenceFilePath = Join-Path -Path $scriptPath -ChildPath 'sentences.json'

    if (-not (Test-Path -Path $sentenceFilePath)) {
        throw "Sentence data file not found: $sentenceFilePath"
    }

    $allLanguageData = Get-Content -Path $sentenceFilePath -Raw | ConvertFrom-Json
    $languageKey = Get-LanguageKey -InputLanguage $InputLanguage
    $languageData = $allLanguageData.$languageKey

    if ($null -eq $languageData) {
        throw "Language section '$languageKey' was not found in sentence data."
    }

    $plan = Get-TemplatePlan -TemplateName $TemplateName -RequestedParagraphCount $RequestedParagraphCount
    if ($TemplateName -eq 'Custom') {
        $plan.IncludeTitle = $RequestedTitle
    }

    $resultParts = [System.Collections.Generic.List[string]]::new()

    if ($plan.IncludeTitle) {
        $title = New-GeneratedTitle -Titles $languageData.titles
        if ($RenderMarkdown) {
            $resultParts.Add("# $title")
        }
        else {
            $resultParts.Add($title)
        }
    }

    if ($plan.IncludePreface) {
        $preface = $languageData.prefaces | Get-Random
        if ($RenderMarkdown) {
            $resultParts.Add("**$preface**")
        }
        else {
            $resultParts.Add($preface)
        }
    }

    $paragraphTargetWords = [Math]::Max(55, [Math]::Floor($plan.ApproxWords / $plan.Paragraphs))

    for ($i = 1; $i -le $plan.Paragraphs; $i++) {
        if ($plan.IncludeSubheadings -and (($i -eq 1) -or ($i % 2 -eq 1))) {
            $subheading = New-SectionHeading -SubtitleWords $languageData.subtitleWords -Index ([Math]::Ceiling($i / 2))
            if ($RenderMarkdown) {
                $resultParts.Add("## $subheading")
            }
            else {
                $resultParts.Add($subheading)
            }
        }

        $variance = Get-Random -Minimum -10 -Maximum 11
        $target = [Math]::Max(45, $paragraphTargetWords + $variance)
        $paragraph = New-Paragraph -SentencePool $languageData.sentences -TargetWordCount $target -Tolerance 7
        $resultParts.Add($paragraph)
    }

    $separator = [Environment]::NewLine + [Environment]::NewLine
    return ($resultParts -join $separator)
}

try {
    $articleText = New-DummyArticleText `
        -TemplateName $Template `
        -InputLanguage $Language `
        -RequestedParagraphCount $ParagraphCount `
        -RenderMarkdown ([bool]$Markdown) `
        -RequestedTitle ([bool]$IncludeTitle)

    $articleText
}
catch {
    Write-Error "Failed to generate dummy text. $($_.Exception.Message)"
    exit 1
}
