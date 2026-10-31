param(
    [Parameter(Mandatory)] [string]$Scene,
    [Parameter(Mandatory)] [string]$Marker,
    [int]$Cols = 120,
    [int]$Rows = 46
)
# Runs one lab step live in this console window. Every command is echoed after a
# PowerShell-style prompt and then actually executed against the cluster.
# Started by capture.ps1, which then saves a PNG of this window.
$ErrorActionPreference = 'Continue'
Set-Location (Resolve-Path "$PSScriptRoot\..\..")
$state = Join-Path (Split-Path $Marker) 'state.txt'

$raw = $Host.UI.RawUI
$raw.BackgroundColor = 'Black'
$raw.ForegroundColor = 'Gray'
$raw.BufferSize = New-Object Management.Automation.Host.Size($Cols, 3000)
$raw.WindowSize = New-Object Management.Automation.Host.Size($Cols, $Rows)
Clear-Host

function prompt { 'PS C:\...\kubernetes-service-discovery> ' }
function Run([string]$cmd) {
    Write-Host -NoNewline (prompt)
    Write-Host $cmd -ForegroundColor Yellow
    Invoke-Expression $cmd | Out-Host
    Write-Host ''
}
function Done {
    Add-Type -Name K -Namespace N -MemberDefinition '[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();'
    [N.K]::GetConsoleWindow().ToInt64() | Set-Content $Marker
}

$NS = 'kubectl -n inventory-lab'
$pods = (kubectl -n inventory-lab get pods -l app=inventory -o jsonpath='{.items[*].metadata.name}').Split(' ')
$A = $pods[0]; $B = $pods[-1]
$podCols = "'custom-columns=NAME:.metadata.name,POD-IP:.status.podIP,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,CREATED:.metadata.creationTimestamp'"
$svcCols = "'custom-columns=NAME:.metadata.name,CLUSTER-IP:.spec.clusterIP,UID:.metadata.uid,CREATED:.metadata.creationTimestamp'"
$svcEndpoints = "$NS describe service inventory-service | findstr /B `"Selector: IP: Endpoints:`""

switch ($Scene) {
    'replicas' {
        $raw.WindowTitle = 'Module 6 lab | 1. Both replicas behind the Service | kubectl context: docker-desktop'
        Run "$NS get pods,services"
        Run $svcEndpoints
        Run "$NS exec deploy/inventory-client -- python client.py resolve"
        Run "$NS exec deploy/inventory-client -- python client.py burst --count 12"
    }
    'unready' {
        $raw.WindowTitle = "Module 6 lab | 2. Readiness failure on $A | kubectl context: docker-desktop"
        Run "$NS get pods -l app=inventory"
        Run "$NS exec $A -- touch /tmp/not-ready"
        Run "$NS wait --for=condition=Ready=false pod/$A --timeout=30s"
        Start-Sleep -Seconds 1
        Run "$NS get pods -l app=inventory"
        Run "$NS exec $A -- python check.py /ready"
        Run "$NS exec $A -- python check.py /healthz"
        Run "$NS get events --field-selector 'involvedObject.name=$A,reason=Unhealthy'"
        Run $svcEndpoints
    }
    'unready-traffic' {
        $raw.WindowTitle = "Module 6 lab | 3. Unready $A gets no traffic | kubectl context: docker-desktop"
        Run "$NS exec $A -- python check.py /stats"
        Run "$NS exec deploy/inventory-client -- python client.py burst --count 12"
        Run "$NS exec $A -- python check.py /stats"
        Run "$NS logs deploy/inventory-client --tail=6"
    }
    'recovery' {
        $raw.WindowTitle = "Module 6 lab | 4. Readiness restored on $A | kubectl context: docker-desktop"
        Run "$NS exec $A -- rm /tmp/not-ready"
        Run "$NS wait --for=condition=Ready pod/$A --timeout=30s"
        Start-Sleep -Seconds 1
        Run "$NS get pods -l app=inventory"
        Run $svcEndpoints
        Run "$NS exec deploy/inventory-client -- python client.py burst --count 12"
        Run "$NS exec $A -- python check.py /stats"
    }
    'watch' {
        $raw.WindowTitle = 'Module 6 lab | 5b. kubectl get pods --watch during the deletion | kubectl context: docker-desktop'
        Write-Host -NoNewline (prompt)
        Write-Host "$NS get pods -l app=inventory --watch --output-watch-events" -ForegroundColor Yellow
        Done
        kubectl -n inventory-lab get pods -l app=inventory --watch --output-watch-events
        return
    }
    'delete' {
        $raw.WindowTitle = "Module 6 lab | 5. Delete $A -> replacement Pod, same Service | kubectl context: docker-desktop"
        Run "$NS get pods -l app=inventory -o $podCols"
        Run "$NS get service inventory-service -o $svcCols"
        (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') | Set-Content $state
        Run "$NS delete pod $A"
        Run "$NS wait --for=condition=Ready pod -l app=inventory --timeout=60s"
        Run "$NS get pods -l app=inventory -o $podCols"
        Run "$NS get service inventory-service -o $svcCols"
        Run "$NS get events --field-selector 'involvedObject.kind=ReplicaSet,reason=SuccessfulCreate' --sort-by=.lastTimestamp"
    }
    'client' {
        $T = (Get-Content $state).Trim()
        $raw.WindowTitle = 'Module 6 lab | 6. Client kept working through the Service | kubectl context: docker-desktop'
        Run "$NS logs deploy/inventory-client --since-time=$T"
        Run "($NS logs deploy/inventory-client --since-time=$T | Select-String FAILED).Count"
        Run "$NS get pods -l app=inventory-client"
        Run "$NS exec deploy/inventory-client -- python client.py resolve"
    }
}
Done
