# Execute end-to-end (e2e) tests to verify that everything is working right
# from the end user perspective
$repoDir = Join-Path $PSScriptRoot ".." | Join-Path -ChildPath ".."
if (-not (Test-Path env:GO_BINARY_PATH)) { $env:GO_BINARY_PATH = "go" }

$globalTmpDir = [System.IO.Path]::GetTempPath()
$tmpDirName = [GUID]::NewGuid()
$testGoPath = Join-Path $globalTmpDir $tmpDirName

$origGOPATH = if (Test-Path env:GOPATH) {$env:GOPATH} else {$null}
$origGOPROXY = if (Test-Path env:GOPROXY) {$env:GOPROXY} else {$null}
$origGO111MODULE = if (Test-Path env:GO111MODULE) {$env:GO111MODULE} else {$null}

New-Item $testGoPath -ItemType Directory | Out-Null
$goModCache = Join-Path $testGoPath "pkg" | Join-Path -ChildPath "mod"
$env:Path += ";" + "${$(Join-Path $repoDir "bin")}"

function clearGoModCache () {
  Get-ChildItem -Path $goModCache -Recurse | Remove-Item -Recurse -Force -Confirm:$false
}

function stopProcesses () {
  Get-Process -Name proxy* -ErrorAction SilentlyContinue | Stop-Process -Force
}

function teardown () {
  # Cleanup ENV after our tests
  if ($origGOPATH) {$env:GOPATH = $origGOPATH} else {Remove-Item env:GOPATH}
  if ($origGOPROXY) {$env:GOPROXY = $origGOPROXY} else {Remove-Item env:GOPROXY}
  if ($origGO111MODULE) {$env:GO111MODULE = $origGO111MODULE} else {Remove-Item env:GO111MODULE}
  stopProcesses
  # clear test gopath
  Get-ChildItem -Path $testGoPath -Recurse | Remove-Item -Recurse -Force -Confirm:$false
  
  Pop-Location 
  Pop-Location
}

try {
  $env:GO111MODULE = "on"
  ## Start the proxy in the background and wait for it to be ready
  Push-Location $(Join-Path $repoDir cmd | Join-Path -ChildPath proxy)
  ## just in case something is still running
  stopProcesses
  & go build -mod=vendor
  Start-Process -NoNewWindow .\proxy.exe

  $proxyUp = $false
  do {
    try {
      $proxyUp = (Invoke-WebRequest  -Method GET -Uri http://localhost:3000/readyz).StatusCode -eq "200"
    }
    catch {
      Start-Sleep -Seconds 1
    }
  } while(-not $proxyUp)

  ## Clone our test repo
  $testSource = Join-Path $testGoPath "happy-path"
  git clone https://github.com/athens-artifacts/happy-path.git ${testSource}
  Push-Location ${testSource}
  
  $env:GOPATH = $testGoPath
  ## Make sure that our test repo works without the GOPROXY first
  if (Test-Path env:GOPROXY) { Remove-Item env:GOPROXY }
  
  & $env:GO_BINARY_PATH run .
  clearGoModCache

  ## Verify that the test works against the proxy
  $env:GOPROXY = "http://localhost:3000"
  & $env:GO_BINARY_PATH run .
}
finally {
  teardown
}
