<#
.SYNOPSIS
  Install or update the Godot MCP Bridge addon into a project from this repo clone.

.DESCRIPTION
  Brings the addon's two parts (addons\godot_mcp and mcp-server) into a target Godot
  project, either by COPY (default, independent per-project copy) or by junction LINK
  (-Link: the project points at this clone, so `git pull` here updates every linked
  project at once). Pulls the clone first unless -NoPull. The project's .mcp.json is
  never touched (it holds per-project port/URL config).

  NOTE: the target's addons\godot_mcp and mcp-server folders are replaced. Close the
  project's Godot editor and stop any running mcp-server first, or the folders will be
  locked and the operation fails.

.PARAMETER Project
  Path to the target Godot project root (must contain project.godot).

.PARAMETER Link
  Create NTFS directory junctions instead of copying (no admin required). `git pull`
  in this clone then updates every linked project instantly.

.PARAMETER Repo
  Path to this repo clone. Defaults to the folder this script lives in.

.PARAMETER NoPull
  Skip `git pull` of the clone.

.EXAMPLE
  .\install.ps1 -Project "D:\Godot\my-game"          # independent copy
.EXAMPLE
  .\install.ps1 -Project "D:\Godot\my-game" -Link    # live-linked to this clone
#>
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [switch]$Link,
    [string]$Repo = $PSScriptRoot,
    [switch]$NoPull
)
$ErrorActionPreference = "Stop"

$Repo = (Resolve-Path $Repo).Path
if (-not (Test-Path (Join-Path $Project "project.godot"))) {
    throw "Not a Godot project (no project.godot found): $Project"
}
$Project = (Resolve-Path $Project).Path
if ($Project -eq $Repo) { throw "Project and clone are the same folder; nothing to do." }

if (-not $NoPull) {
    Write-Host "Pulling latest in $Repo ..."
    git -C $Repo pull --ff-only
}

foreach ($rel in @("addons\godot_mcp", "mcp-server")) {
    $src = Join-Path $Repo $rel
    $dst = Join-Path $Project $rel
    if (-not (Test-Path $src)) { throw "Missing in clone: $src" }

    $parent = Split-Path $dst -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    # Remove any existing target: just the link if it's a junction, else the whole folder.
    if (Test-Path $dst) {
        $item = Get-Item $dst -Force
        if ($item.LinkType) {
            [System.IO.Directory]::Delete($dst, $false)
        } else {
            Write-Host "Replacing existing $rel (local changes there are discarded)..."
            Remove-Item -Recurse -Force $dst
        }
    }

    if ($Link) {
        New-Item -ItemType Junction -Path $dst -Target $src | Out-Null
        Write-Host "LINK  $rel  ->  $src"
    } else {
        # /MIR mirrors; /XD keeps each project's own venv/cache out of it.
        robocopy $src $dst /MIR /XD .venv __pycache__ .git /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $rel (exit $LASTEXITCODE)" }
        Write-Host "COPY  $rel"
    }
}

$mode = if ($Link) { "linked" } else { "copied" }
Write-Host ""
Write-Host "Done ($mode). .mcp.json left untouched."
Write-Host "In Godot: Project Settings, Plugins, enable 'Godot MCP Bridge'."
