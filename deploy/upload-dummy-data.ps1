param(
    [string]$EnvPath = "$PSScriptRoot\deploy-env.json"
)

function Write-Step([string]$Script, [string]$Message) {
    Write-Host "`n[$Script] $Message" -ForegroundColor Cyan
}

if (-not (Test-Path $EnvPath)) {
    Write-Error "deploy-env.json not found. Run deploy.ps1 first."
    exit 1
}

$env = Get-Content $EnvPath | ConvertFrom-Json
$storageAccount = $env.storageAccountName
$scriptName = "upload-dummy-data"

# Generate sample PDFs using Python
Write-Step $scriptName "1. Generating sample PDFs"
$tempDir = Join-Path $PSScriptRoot "_temp_pdfs"
if (Test-Path $tempDir) { Remove-Item -Recurse -Force $tempDir }
New-Item -ItemType Directory -Path $tempDir | Out-Null

$pyScript = @"
import os, sys
d = sys.argv[1]
def pdf(fn, title, body):
    t = title.replace('(',r'\(').replace(')',r'\)')
    b = body.replace('(',r'\(').replace(')',r'\)')
    s = f'BT /F1 16 Tf 50 750 Td ({t}) Tj ET BT /F1 11 Tf 50 720 Td ({b}) Tj ET'
    sb = s.encode('latin-1'); l = len(sb)
    lines = [b'%PDF-1.4',
        b'1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj',
        b'2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj',
        b'3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj',
        f'4 0 obj<</Length {l}>>stream\n'.encode('latin-1') + sb + b'\nendstream endobj',
        b'5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj']
    bb = b'\n'.join(lines)
    xo = len(bb)+1; xr = f'\nxref\n0 6\n0000000000 65535 f \n'
    o = 9
    for ln in lines[1:]: xr += f'{o:010d} 00000 n \n'; o += len(ln)+1
    xr += f'trailer<</Size 6/Root 1 0 R>>\nstartxref\n{xo}\n%%EOF'
    with open(os.path.join(d,fn),'wb') as f: f.write(bb+xr.encode('latin-1'))
pdf('nda-acme-2026.pdf','NDA - Acme Corp','Effective: Jan 15 2026. Parties: Acme Corp and Contoso Ltd.')
pdf('nda-globex-2026.pdf','NDA - Globex Inc','Effective: Feb 1 2026. Parties: Globex Inc and Contoso Ltd.')
pdf('nda-initech-2025.pdf','NDA - Initech','Effective: Nov 10 2025. Parties: Initech and Contoso Ltd.')
pdf('invoice-001.pdf','Invoice 001','Amount: USD 12500. Due: Mar 30 2026. Vendor: Acme Corp.')
pdf('invoice-002.pdf','Invoice 002','Amount: USD 8750. Due: Apr 15 2026. Vendor: Globex Inc.')
pdf('invoice-003.pdf','Invoice 003','Amount: USD 3200. Due: May 1 2026. Vendor: Initech.')
pdf('report-q1-2026.pdf','Q1 2026 Financial Report','Revenue: USD 1.2M. Expenses: USD 890K. Net: USD 310K.')
pdf('sow-project-alpha.pdf','SOW - Project Alpha','Duration: 6 months. Budget: USD 450000. Start: Feb 2026.')
print('Generated 8 PDFs')
"@

python -c $pyScript $tempDir

# Upload to Azure Storage
$uploads = @(
    @{ local = "nda-acme-2026.pdf";     remote = "contracts/nda-acme-2026.pdf" },
    @{ local = "nda-globex-2026.pdf";   remote = "contracts/nda-globex-2026.pdf" },
    @{ local = "nda-initech-2025.pdf";  remote = "contracts/nda-initech-2025.pdf" },
    @{ local = "sow-project-alpha.pdf"; remote = "contracts/sow-project-alpha.pdf" },
    @{ local = "invoice-001.pdf";       remote = "invoices/2026/invoice-001.pdf" },
    @{ local = "invoice-002.pdf";       remote = "invoices/2026/invoice-002.pdf" },
    @{ local = "invoice-003.pdf";       remote = "invoices/2026/invoice-003.pdf" },
    @{ local = "report-q1-2026.pdf";    remote = "reports/report-q1-2026.pdf" }
)

Write-Step $scriptName "2. Uploading to storage account '$storageAccount'"
foreach ($u in $uploads) {
    $localPath = Join-Path $tempDir $u.local
    az storage blob upload `
        --account-name $storageAccount `
        --container-name data `
        --name $u.remote `
        --file $localPath `
        --auth-mode login `
        --overwrite | Out-Null
    Write-Output "    Uploaded: $($u.remote)"
}

# Upload a sample text file
Write-Step $scriptName "3. Uploading sample text blob"
$txtFile = Join-Path $tempDir "readme.txt"
"This is a test file uploaded by the deploy script." | Set-Content -Path $txtFile
az storage blob upload `
    --account-name $storageAccount `
    --container-name data `
    --name "notes/readme.txt" `
    --file $txtFile `
    --auth-mode login `
    --overwrite | Out-Null
Write-Output "    Uploaded: notes/readme.txt"

# Cleanup
Remove-Item -Recurse -Force $tempDir

Write-Step $scriptName "DUMMY DATA UPLOAD COMPLETE"
Write-Output ""
Write-Output "  Uploaded 9 files to container 'data' in '$storageAccount'"
Write-Output ""
Write-Output "  contracts/nda-acme-2026.pdf"
Write-Output "  contracts/nda-globex-2026.pdf"
Write-Output "  contracts/nda-initech-2025.pdf"
Write-Output "  contracts/sow-project-alpha.pdf"
Write-Output "  invoices/2026/invoice-001.pdf"
Write-Output "  invoices/2026/invoice-002.pdf"
Write-Output "  invoices/2026/invoice-003.pdf"
Write-Output "  reports/report-q1-2026.pdf"
Write-Output "  notes/readme.txt"
