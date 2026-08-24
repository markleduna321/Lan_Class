# Builds a minimal but structurally valid PDF with computed xref offsets.
$ErrorActionPreference = 'Stop'

$text = @(
  'Networking Basics - Lesson 1',
  'The OSI model has seven layers.',
  'Layer 1 is the Physical layer which transmits raw bits.',
  'Layer 2 is the Data Link layer which uses MAC addresses.',
  'Layer 3 is the Network layer which uses IP addresses for routing.',
  'Layer 4 is the Transport layer where TCP and UDP operate.',
  'TCP is connection oriented and reliable.',
  'UDP is connectionless and faster but unreliable.',
  'A router forwards packets between different networks.',
  'A switch forwards frames within the same network.'
)

$stream = "BT /F1 12 Tf 50 740 Td"
foreach ($line in $text) { $stream += " ($line) Tj 0 -20 Td" }
$stream += " ET"

$objects = @(
  "<< /Type /Catalog /Pages 2 0 R >>",
  "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
  "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
  "<< /Length $($stream.Length) >>`nstream`n$stream`nendstream",
  "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
)

$pdf = "%PDF-1.4`n"
$offsets = New-Object System.Collections.Generic.List[int]
for ($i = 0; $i -lt $objects.Count; $i++) {
  $offsets.Add($pdf.Length)
  $pdf += "$($i + 1) 0 obj`n$($objects[$i])`nendobj`n"
}
$xrefPos = $pdf.Length
$pdf += "xref`n0 $($objects.Count + 1)`n0000000000 65535 f `n"
foreach ($off in $offsets) { $pdf += ('{0:d10} 00000 n ' -f $off) + "`n" }
$pdf += "trailer`n<< /Size $($objects.Count + 1) /Root 1 0 R >>`nstartxref`n$xrefPos`n%%EOF"

$path = "$env:TEMP\qa_networking_valid.pdf"
[IO.File]::WriteAllText($path, $pdf, [Text.Encoding]::ASCII)
"Written: $((Get-Item $path).Length) bytes"
