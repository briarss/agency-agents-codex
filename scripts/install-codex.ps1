<#
.SYNOPSIS
Converts The Agency Markdown agents into Codex native subagents and skills.

.DESCRIPTION
Reads agent Markdown files from the standard Agency category directories, converts
each one to a Codex native `.toml` agent, and writes matching skill wrappers to
`~/.codex/skills` by default. Generated names are prefixed with `agency-` to
avoid overwriting existing Codex or oh-my-codex role agents.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\scripts\install-codex.ps1

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\scripts\install-codex.ps1 -Scope project

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\scripts\install-codex.ps1 -Mode skills -SkillsMode router

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\scripts\install-codex.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [ValidateSet("user", "project")]
  [string]$Scope = "user",

  [ValidateSet("agents", "skills", "both")]
  [string]$Mode = "both",

  [ValidateSet("router", "individual", "both")]
  [string]$SkillsMode = "both",

  [string]$Destination,

  [string]$SkillsDestination,

  [string]$Prefix = "agency-",

  [ValidateSet("low", "medium", "high", "xhigh")]
  [string]$ReasoningEffort = "medium",

  [string]$Model = "gpt-5.4-mini",

  [switch]$Clean
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Prefix) -or $Prefix -match '[\\/]') {
  throw "Prefix must be a non-empty filename-safe prefix."
}

if ([string]::IsNullOrWhiteSpace($Model)) {
  throw "Model must be a non-empty Codex model id."
}

$ScriptRoot = Split-Path -Parent $PSCommandPath
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $ScriptRoot "..")).Path
$HomeDir = if ($HOME) { $HOME } else { [Environment]::GetFolderPath("UserProfile") }

if ([string]::IsNullOrWhiteSpace($Destination)) {
  if ($Scope -eq "project") {
    $Destination = Join-Path (Get-Location).Path ".codex\agents"
  } else {
    $Destination = Join-Path $HomeDir ".codex\agents"
  }
}

if ([string]::IsNullOrWhiteSpace($SkillsDestination)) {
  if ($Scope -eq "project") {
    $SkillsDestination = Join-Path (Get-Location).Path ".codex\skills"
  } else {
    $SkillsDestination = Join-Path $HomeDir ".codex\skills"
  }
}

$AgentDirs = @(
  "academic",
  "design",
  "engineering",
  "finance",
  "game-development",
  "marketing",
  "paid-media",
  "product",
  "project-management",
  "sales",
  "spatial-computing",
  "specialized",
  "strategy",
  "support",
  "testing"
)

function ConvertTo-Slug {
  param([Parameter(Mandatory = $true)][string]$Value)

  return (($Value.ToLowerInvariant() -replace '[^a-z0-9]+', '-') -replace '^-|-$', '')
}

function Escape-TomlBasicString {
  param([AllowNull()][string]$Value)

  if ($null -eq $Value) {
    return ""
  }

  $builder = New-Object System.Text.StringBuilder
  foreach ($ch in $Value.ToCharArray()) {
    $code = [int][char]$ch
    if ($ch -eq '\') {
      [void]$builder.Append('\\')
    } elseif ($ch -eq '"') {
      [void]$builder.Append('\"')
    } elseif ($code -lt 0x20) {
      [void]$builder.Append(('\u{0:x4}' -f $code))
    } else {
      [void]$builder.Append($ch)
    }
  }

  return $builder.ToString()
}

function Escape-TomlMultilineBasicString {
  param([AllowNull()][string]$Value)

  if ($null -eq $Value) {
    return ""
  }

  $builder = New-Object System.Text.StringBuilder
  foreach ($ch in $Value.ToCharArray()) {
    $code = [int][char]$ch
    if ($ch -eq "`n") {
      [void]$builder.Append("`n")
    } elseif ($ch -eq '\') {
      [void]$builder.Append('\\')
    } elseif ($ch -eq '"') {
      [void]$builder.Append('\"')
    } elseif ($code -eq 0x09) {
      [void]$builder.Append('\t')
    } elseif ($code -lt 0x20) {
      [void]$builder.Append(('\u{0:x4}' -f $code))
    } else {
      [void]$builder.Append($ch)
    }
  }

  return $builder.ToString()
}

function Escape-YamlSingleQuoted {
  param([AllowNull()][string]$Value)

  if ($null -eq $Value) {
    return ""
  }

  return $Value.Replace("'", "''")
}

function Get-RelativePath {
  param(
    [Parameter(Mandatory = $true)][string]$BasePath,
    [Parameter(Mandatory = $true)][string]$FullPath
  )

  $base = $BasePath.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
  if ($FullPath.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
    return $FullPath.Substring($base.Length).Replace('\', '/')
  }

  return (Split-Path -Leaf $FullPath)
}

function Read-AgentFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  $lines = [System.IO.File]::ReadAllLines($Path)
  if ($lines.Count -lt 3 -or $lines[0].Trim() -ne "---") {
    return $null
  }

  $frontmatterEnd = -1
  for ($i = 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Trim() -eq "---") {
      $frontmatterEnd = $i
      break
    }
  }

  if ($frontmatterEnd -lt 0) {
    return $null
  }

  $frontmatter = @{}
  for ($i = 1; $i -lt $frontmatterEnd; $i++) {
    if ($lines[$i] -match '^([^:#][^:]*):\s*(.*)$') {
      $key = $matches[1].Trim()
      $value = $matches[2].Trim()
      if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        $value = $value.Substring(1, $value.Length - 2)
      }
      $frontmatter[$key] = $value
    }
  }

  if (-not $frontmatter.ContainsKey("name") -or -not $frontmatter.ContainsKey("description")) {
    return $null
  }

  $body = ""
  if ($frontmatterEnd + 1 -lt $lines.Count) {
    $body = [string]::Join("`n", $lines[($frontmatterEnd + 1)..($lines.Count - 1)])
  }

  return [pscustomobject]@{
    Name = $frontmatter["name"]
    Description = $frontmatter["description"]
    Body = $body
  }
}

function Test-GeneratedSkillDirectory {
  param([Parameter(Mandatory = $true)][string]$Path)

  $skillFile = Join-Path $Path "SKILL.md"
  if (-not (Test-Path -LiteralPath $skillFile)) {
    return $false
  }

  try {
    return (Select-String -LiteralPath $skillFile -SimpleMatch "Generated by scripts/install-codex.ps1" -Quiet)
  } catch {
    return $false
  }
}

function Write-SkillFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][System.Text.Encoding]$Encoding
  )

  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) {
    if ($PSCmdlet.ShouldProcess($dir, "Create Codex skill directory")) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
  }

  if ($PSCmdlet.ShouldProcess($Path, "Write Codex skill")) {
    [System.IO.File]::WriteAllText($Path, $Content, $Encoding)
    return 1
  }

  return 0
}

function New-IndividualSkillContent {
  param(
    [Parameter(Mandatory = $true)]$Agent,
    [Parameter(Mandatory = $true)][string]$Prefix
  )

  $description = Escape-YamlSingleQuoted "Agency specialist wrapper for $($Agent.Name). Delegates to native subagent $($Agent.Slug) when available; otherwise runs the same role inline."
  $trigger = '$' + $Agent.Slug

  return @"
---
name: $($Agent.Slug)
description: '$description'
---

# $($Agent.Name) Agency Skill

Generated by scripts/install-codex.ps1 from source file: $($Agent.RelativePath).

## Use When

Use this skill when the user explicitly asks for $($Agent.Name), $trigger, or needs this specialist's domain.

## Execution

1. Treat this skill as a specialist role activation, not a top-level workflow.
2. If native subagent delegation is available, spawn agent type $($Agent.Slug) with the user's concrete task.
3. If spawning is unavailable or returns unknown agent_type, continue inline using the role prompt below.
4. Keep all higher-priority Codex, workspace AGENTS.md, and user instructions above this skill.
5. Keep outputs concise and evidence-grounded unless the task requires detail.

## Native Agent

$($Agent.Slug)

## Inline Fallback Prompt

You are the $($Agent.Name) specialist from The Agency.
This skill defines role focus only. Follow all higher-priority Codex, workspace AGENTS.md, and user instructions.

Source file: $($Agent.RelativePath)

$($Agent.Body)
"@
}

function New-RouterSkillContent {
  param(
    [Parameter(Mandatory = $true)][object[]]$Agents,
    [Parameter(Mandatory = $true)][string]$Prefix
  )

  $routerTrigger = '$agency'
  $roster = ($Agents | Sort-Object Slug | ForEach-Object {
    "- $($_.Slug) - $($_.Name): $($_.Description)"
  }) -join "`n"

  return @"
---
name: agency
description: 'Route requests to The Agency specialists and their agency-* native subagents or skill wrappers.'
---

# Agency Router Skill

Generated by scripts/install-codex.ps1.

## Use When

Use $routerTrigger when the user wants one of The Agency specialists, asks which specialist fits a task, or references an Agency role without remembering the exact slug.

## Execution

1. Parse the user's task and identify the best specialist from the roster.
2. Prefer an explicitly named specialist when the user provides one.
3. If native subagent delegation is available, spawn the matching agency-* agent with a bounded task.
4. If native delegation is unavailable or returns unknown agent_type, use the matching dollar-prefixed skill wrapper when installed, or continue inline from the source Agency prompt if you have it in context.
5. For broad tasks, pick at most three specialists and explain the division of work before delegating.
6. Keep all higher-priority Codex, workspace AGENTS.md, and user instructions above this router.

## Roster

$roster
"@
}

$installAgents = $Mode -eq "agents" -or $Mode -eq "both"
$installSkills = $Mode -eq "skills" -or $Mode -eq "both"
$installRouterSkill = $installSkills -and ($SkillsMode -eq "router" -or $SkillsMode -eq "both")
$installIndividualSkills = $installSkills -and ($SkillsMode -eq "individual" -or $SkillsMode -eq "both")

if ($installAgents -and -not (Test-Path -LiteralPath $Destination)) {
  if ($PSCmdlet.ShouldProcess($Destination, "Create Codex agents directory")) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
  }
}

if ($installSkills -and -not (Test-Path -LiteralPath $SkillsDestination)) {
  if ($PSCmdlet.ShouldProcess($SkillsDestination, "Create Codex skills directory")) {
    New-Item -ItemType Directory -Path $SkillsDestination -Force | Out-Null
  }
}

if ($Clean -and $installAgents -and (Test-Path -LiteralPath $Destination)) {
  Get-ChildItem -LiteralPath $Destination -Filter "$Prefix*.toml" -File | ForEach-Object {
    $firstLine = ""
    try {
      $firstLine = [System.IO.File]::ReadLines($_.FullName) | Select-Object -First 1
    } catch {
      $firstLine = ""
    }

    if ($firstLine -like "# Generated by scripts/install-codex.ps1*" -or $firstLine -like "# Generated by scripts/convert.sh*") {
      if ($PSCmdlet.ShouldProcess($_.FullName, "Remove previously generated Codex agent")) {
        Remove-Item -LiteralPath $_.FullName -Force
      }
    }
  }
}

if ($Clean -and $installSkills -and (Test-Path -LiteralPath $SkillsDestination)) {
  $skillDirs = @()
  $routerDir = Join-Path $SkillsDestination "agency"
  if ($installRouterSkill -and (Test-Path -LiteralPath $routerDir)) {
    $skillDirs += Get-Item -LiteralPath $routerDir
  }
  if ($installIndividualSkills) {
    $skillDirs += Get-ChildItem -LiteralPath $SkillsDestination -Directory -Filter "$Prefix*"
  }

  $skillDirs | Sort-Object FullName -Unique | ForEach-Object {
    if (Test-GeneratedSkillDirectory -Path $_.FullName) {
      if ($PSCmdlet.ShouldProcess($_.FullName, "Remove previously generated Codex skill")) {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force
      }
    }
  }
}

$Utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
$agents = @()
$preparedAgents = 0
$writtenAgents = 0
$writtenSkills = 0

foreach ($dir in $AgentDirs) {
  $dirPath = Join-Path $RepoRoot $dir
  if (-not (Test-Path -LiteralPath $dirPath)) {
    continue
  }

  Get-ChildItem -LiteralPath $dirPath -Recurse -Filter "*.md" -File | Sort-Object FullName | ForEach-Object {
    $agent = Read-AgentFile -Path $_.FullName
    if ($null -eq $agent) {
      return
    }

    $slug = $Prefix + (ConvertTo-Slug $agent.Name)
    $relativePath = Get-RelativePath -BasePath $RepoRoot -FullPath $_.FullName
    $agentInfo = [pscustomobject]@{
      Name = $agent.Name
      Description = $agent.Description
      Body = $agent.Body
      Slug = $slug
      RelativePath = $relativePath
    }
    $agents += $agentInfo

    $instructions = @"
You are the $($agent.Name) specialist from The Agency.
This Codex native subagent prompt defines role focus only. Follow all higher-priority Codex, workspace AGENTS.md, and user instructions.

Source file: $relativePath

$($agent.Body)
"@

    if ($installAgents) {
      $outPath = Join-Path $Destination "$slug.toml"
      $escapedDescription = Escape-TomlBasicString $agent.Description
      $escapedModel = Escape-TomlBasicString $Model
      $escapedInstructions = Escape-TomlMultilineBasicString $instructions
      $toml = @"
# Generated by scripts/install-codex.ps1. Do not edit manually.
# Source: $relativePath
name = "$slug"
description = "$escapedDescription"
model = "$escapedModel"
model_reasoning_effort = "$ReasoningEffort"
developer_instructions = """
$escapedInstructions
"""
"@

      $preparedAgents++
      if ($PSCmdlet.ShouldProcess($outPath, "Write Codex native agent")) {
        [System.IO.File]::WriteAllText($outPath, $toml, $Utf8NoBom)
        $writtenAgents++
      }
    }
  }
}

if ($installRouterSkill) {
  $routerContent = New-RouterSkillContent -Agents $agents -Prefix $Prefix
  $routerPath = Join-Path (Join-Path $SkillsDestination "agency") "SKILL.md"
  $writtenSkills += Write-SkillFile -Path $routerPath -Content $routerContent -Encoding $Utf8NoBom
}

if ($installIndividualSkills) {
  foreach ($agent in $agents) {
    $skillContent = New-IndividualSkillContent -Agent $agent -Prefix $Prefix
    $skillPath = Join-Path (Join-Path $SkillsDestination $agent.Slug) "SKILL.md"
    $writtenSkills += Write-SkillFile -Path $skillPath -Content $skillContent -Encoding $Utf8NoBom
  }
}

Write-Host "Discovered $($agents.Count) Agency source agents."
if ($installAgents) {
  Write-Host "Prepared $preparedAgents Codex native agents."
  Write-Host "Installed $writtenAgents agent files to $Destination"
  Write-Host "Example native agent type: $($Prefix)frontend-developer"
}
if ($installSkills) {
  Write-Host "Installed $writtenSkills skill file(s) to $SkillsDestination"
  Write-Host 'Example skill trigger: $agency'
  if ($installIndividualSkills) {
    Write-Host ("Example individual skill trigger: $" + $Prefix + "frontend-developer")
  }
}
Write-Host "Start a new Codex session to refresh native agents and skill autocomplete."
