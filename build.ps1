# =====================================================================
#  MedMasterPlan  -  Dashboard data engine  (campanha MMP-29-30AGO)
#  Baixa 2 planilhas Google (CSV export), cruza leads x queries do Meta,
#  calcula o Leadscore A/B/C e escreve data.js (window.MMP) lido pela
#  pagina estatica (index.html). Roda local (PS 5.1) e no GitHub Actions.
#  Somente leitura - NAO altera nenhuma planilha.  ASCII-only de proposito
#  (PS5.1 le .ps1 como ANSI; acentos so no front app.js).
# =====================================================================
param([ValidateSet('all')][string]$Mode='all')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$BR = [Globalization.CultureInfo]::GetCultureInfo('pt-BR')
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir = Join-Path $root 'data'
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

# ---- Fontes (somente leitura) --------------------------------------
$QUERIES_ID = '19iZ09ShcF2OUAmyXAiwEWfikL-y0E1Jr2gs1qmtbHi4'; $QUERIES_GID = '0'   # aba "MMP-29-30AGO | QUERIES META"
$LEADS_ID   = '1O0V1rTwmSVYbiyxisHz3svlEIco1qs-MsPrwNl96Ac4'; $LEADS_GID   = '0'   # Lista de Leads
$TAX = 1.1385      # imposto Meta (+13,85%) aplicado em TODO gasto
$AGENCY = 'agenciaup13'   # e-mail interno da agencia = lead de teste

function Get-Sheet($id,$gid,$out){
  $url = "https://docs.google.com/spreadsheets/d/$id/gviz/tq?tqx=out:csv&gid=$gid"
  [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
  (New-Object System.Net.WebClient).DownloadFile($url,$out)
  if((Get-Item $out).Length -lt 30){ throw "Download muito pequeno: $out" }
}
Add-Type -AssemblyName Microsoft.VisualBasic
function Read-Csv($path){
  $rows = New-Object System.Collections.Generic.List[object]
  $p = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($path,[System.Text.Encoding]::UTF8)
  $p.TextFieldType='Delimited'; $p.SetDelimiters(','); $p.HasFieldsEnclosedInQuotes=$true
  while(-not $p.EndOfData){ $rows.Add($p.ReadFields()) }
  $p.Close(); return $rows
}
function Norm($s){ if($null -eq $s){return ''}; return ($s -replace [char]0x200b,'').Trim() }
function MoneyBR($s){ $s=Norm $s; if($s -eq ''){return 0.0}; return [double]($s -replace '\.','' -replace ',','.') }
function ToInt($s){ $s=Norm $s; if($s -eq ''){return 0}; $v=($s -replace '\.','' -replace ',','.'); if($v -notmatch '^-?\d'){return 0}; return [int][double]$v }
function Deaccent($s){ if($null -eq $s){return ''}; $s=$s.Normalize([Text.NormalizationForm]::FormD); $sb=New-Object Text.StringBuilder
  foreach($c in $s.ToCharArray()){ if([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [Globalization.UnicodeCategory]::NonSpacingMark){ [void]$sb.Append($c) } }
  return $sb.ToString().ToLower().Trim() }
function HdrLike($hdr,$frag){ for($i=0;$i -lt $hdr.Count;$i++){ if((Deaccent $hdr[$i]) -like $frag){ return $i } }; return -1 }
function TitleFirst($s){ $s=(Norm $s) -replace '\s+',' '; if($s -eq ''){return ''}; return $s.Substring(0,1).ToUpper()+$s.Substring(1) }
# dd-mm-yyyy -> yyyy-mm-dd
function LeadDate($s){ $s=Norm $s; if($s -match '^(\d{1,2})[-/](\d{1,2})[-/](\d{4})'){ return ('{0}-{1:d2}-{2:d2}' -f $Matches[3],[int]$Matches[2],[int]$Matches[1]) }; return '' }

# ---- Leadscore A/B/C (regras do cliente) ---------------------------
#   A = faturamento acima de R$ 1 milhao/ano
#   B = faturamento R$ 500mil a 1 milhao/ano  +  possui clinica  +  5+ anos de formado
#   C = demais (nao qualificado).   Qualificado = A + B.
# nivel de faturamento (casa pela cota INFERIOR do balde p/ nao confundir 200-500 com 500-1M):
function FatLevel($fat){
  $f = Deaccent $fat
  if($f -eq ''){ return 0 }
  if($f -match 'acima' -and $f -match 'milh'){ return 5 }        # acima de 1 milhao
  if($f -match 'de 500' -or $f -match '^500 ?mil'){ return 4 }   # 500mil a 1 milhao
  if($f -match 'de 200' -or $f -match '^200 ?mil'){ return 3 }   # 200mil a 500mil
  if($f -match 'de 50'  -or $f -match '^50 ?mil'){ return 2 }    # 50mil a 200mil
  if($f -match 'abaixo' -or $f -match 'menos' -or $f -match 'ate 50'){ return 1 }
  return 0
}
function FormadoYears($s){
  $d = Deaccent $s; if($d -notmatch '(\d+)'){ return -1 }
  $n = [int]$Matches[1]; if($d -match 'menos'){ $n = $n - 1 }; return $n
}
function TierMMP($fatLevel,$hasClin,$anos){
  if($fatLevel -ge 5){ return 'A' }
  if($fatLevel -ge 4 -and $hasClin -and $anos -ge 5){ return 'B' }
  return 'C'
}
# lead de teste: macro {{...}} nas utms, source/medium = "teste*", e-mail da agencia,
# ou linha sem NENHUMA utm preenchida. NAO olha utm_campaign p/ "teste" (o nome real
# da campanha contem "Teste de criativos").
function IsTest($mail,$src,$med,$camp,$cont,$term){
  foreach($u in @($src,$med,$camp,$cont,$term)){ if($u -match '\{\{|\}\}'){ return $true } }
  $s=Deaccent $src; $m=Deaccent $med
  if($s -eq 'teste' -or $s -like 'teste[-_ ]*'){ return $true }
  if($m -eq 'teste' -or $m -like 'teste[-_ ]*'){ return $true }
  if((Deaccent $mail) -like "*$AGENCY*"){ return $true }
  $anyUtm=$false; foreach($u in @($src,$med,$camp,$cont,$term)){ if((Norm $u) -ne ''){ $anyUtm=$true; break } }
  if(-not $anyUtm){ return $true }
  return $false
}

Write-Host "Baixando planilhas..."
$qCsv=Join-Path $dataDir 'queries.csv'; $lCsv=Join-Path $dataDir 'leads.csv'
Get-Sheet $QUERIES_ID $QUERIES_GID $qCsv
Get-Sheet $LEADS_ID   $LEADS_GID   $lCsv
$q = Read-Csv $qCsv; $qh=$q[0]; $qd=$q[1..($q.Count-1)]
$l = Read-Csv $lCsv; $lh=$l[0]; $ld=$l[1..($l.Count-1)]

# ---- indices de coluna ---------------------------------------------
$Q_DAY=HdrLike $qh 'day'; $Q_CAMP=HdrLike $qh 'campaign name'; $Q_SET=HdrLike $qh 'ad set name'; $Q_AD=HdrLike $qh 'ad name'
$Q_SPEND=HdrLike $qh 'amount spent'; $Q_IMP=HdrLike $qh 'impressions'; $Q_CLK=HdrLike $qh 'link clicks'
$Q_LPV=HdrLike $qh 'landing page views'; $Q_ML=HdrLike $qh 'leads'; $Q_V3=HdrLike $qh '*second video*'; $Q_V75=HdrLike $qh '*at 75*'

$L_DATE=HdrLike $lh '*criacao*'; $L_MAIL=HdrLike $lh '*email*'; $L_TEL=HdrLike $lh '*telefone*'
$L_UMED=HdrLike $lh 'utm_medium'; $L_UCAMP=HdrLike $lh 'utm_campaign'; $L_USRC=HdrLike $lh 'utm_source'
$L_UCONT=HdrLike $lh 'utm_content'; $L_UTERM=HdrLike $lh 'utm_term'
$L_FAT=HdrLike $lh '*faturamento*'; $L_CLIN=HdrLike $lh '*clinica*'; $L_ESP=HdrLike $lh '*especialidade*'
$L_FORM=HdrLike $lh '*formado*'; $L_PREF=HdrLike $lh '*prefere*'

# checagem de sanidade dos headers essenciais
foreach($pair in @(@('Day',$Q_DAY),@('Campaign',$Q_CAMP),@('Amount Spent',$Q_SPEND),@('data',$L_DATE),@('utm_campaign',$L_UCAMP),@('faturamento',$L_FAT),@('clinica',$L_CLIN),@('formado',$L_FORM))){
  if($pair[1] -lt 0){ throw ("Coluna nao encontrada: "+$pair[0]) }
}

# ---- nomes reais das queries (p/ casar a atribuicao) ---------------
$campSet=@(); $adSet=@(); $adsetSet=@(); $adToAdset=@{}; $campDe=@{}; $adDe=@{}; $adsetDe=@{}
foreach($r in $qd){
  $cn=Norm $r[$Q_CAMP]; $sn=Norm $r[$Q_SET]; $an=Norm $r[$Q_AD]
  if($cn -ne '' -and ($campSet -notcontains $cn)){ $campSet+=$cn; $campDe[(Deaccent $cn)]=$cn }
  if($an -ne '' -and ($adSet -notcontains $an)){ $adSet+=$an; $adDe[(Deaccent $an)]=$an }
  if($sn -ne '' -and ($adsetSet -notcontains $sn)){ $adsetSet+=$sn; $adsetDe[(Deaccent $sn)]=$sn }
  if($an -ne '' -and $sn -ne '' -and -not $adToAdset.ContainsKey($an)){ $adToAdset[$an]=$sn }
}
function MatchName($val,$exactSet,$deMap){ $v=Norm $val; if($v -eq ''){return ''}; if($exactSet -contains $v){return $v}; $d=Deaccent $v; if($deMap.ContainsKey($d)){return $deMap[$d]}; return '' }

# ===================================================================
#  DAILY (funil por dia) + GRAIN (dia|campanha|conjunto|anuncio)
# ===================================================================
$daily=@{}
function GetDay($d){ if(-not $daily.ContainsKey($d)){ $daily[$d]=[pscustomobject]@{date=$d;spend=0.0;impr=0;clicks=0;lpv=0;v3=0;v75=0;metaLeads=0;leads=0;A=0;B=0;C=0} }; return $daily[$d] }
$grain=@{}
function GetGrain($d,$c,$s,$a){ $key="$d`u$c`u$s`u$a"
  if(-not $grain.ContainsKey($key)){ $grain[$key]=[pscustomobject]@{date=$d;campaign=$c;adset=$s;ad=$a;spend=0.0;impr=0;clicks=0;lpv=0;v3=0;v75=0;metaLeads=0;leads=0;A=0;B=0;C=0} }
  return $grain[$key] }

foreach($r in $qd){ $d=Norm $r[$Q_DAY]; if($d -notmatch '^\d{4}-\d{2}-\d{2}$'){continue}
  $sp=(MoneyBR $r[$Q_SPEND])*$TAX; $im=ToInt $r[$Q_IMP]; $ck=ToInt $r[$Q_CLK]; $lp=ToInt $r[$Q_LPV]
  $v3=ToInt $r[$Q_V3]; $v75=ToInt $r[$Q_V75]; $ml=ToInt $r[$Q_ML]
  $o=GetDay $d; $o.spend+=$sp;$o.impr+=$im;$o.clicks+=$ck;$o.lpv+=$lp;$o.v3+=$v3;$o.v75+=$v75;$o.metaLeads+=$ml
  $g=GetGrain $d (Norm $r[$Q_CAMP]) (Norm $r[$Q_SET]) (Norm $r[$Q_AD])
  $g.spend+=$sp;$g.impr+=$im;$g.clicks+=$ck;$g.lpv+=$lp;$g.v3+=$v3;$g.v75+=$v75;$g.metaLeads+=$ml }

# ---- leads: filtra teste, pontua, classifica e atribui -------------
$SENT='SEM_RASTREIO'
$leadRows=New-Object System.Collections.Generic.List[object]
$dFatA=@{}; $dEspA=@{}; $dFormA=@{}; $dClinA=@{}; $dPrefA=@{}
$dFatQ=@{}; $dEspQ=@{}; $dFormQ=@{}; $dPrefQ=@{}
$nTest=0
function Bump($h,$k){ if($null -eq $k -or $k -eq ''){return}; if(-not $h.ContainsKey($k)){$h[$k]=0}; $h[$k]++ }

foreach($r in $ld){
  if($r.Count -le $L_PREF){ continue }
  $mail=Norm $r[$L_MAIL]; $src=Norm $r[$L_USRC]; $med=Norm $r[$L_UMED]; $camp=Norm $r[$L_UCAMP]; $cont=Norm $r[$L_UCONT]; $term=Norm $r[$L_UTERM]
  if(IsTest $mail $src $med $camp $cont $term){ $nTest++; continue }
  $d=LeadDate $r[$L_DATE]; if($d -eq ''){ $d='sem-data' }
  $fatLevel=FatLevel $r[$L_FAT]
  $hasClin=((Deaccent $r[$L_CLIN]) -match 'sim')
  $anos=FormadoYears $r[$L_FORM]
  $tier=TierMMP $fatLevel $hasClin $anos
  # atribuicao: utm_campaign->Campaign ; utm_content->Ad ; utm_medium->Ad Set
  $cName=MatchName $camp $campSet $campDe; if($cName -eq ''){ $cName=$SENT }
  $aName=MatchName $cont $adSet $adDe; if($aName -eq ''){ $aName=MatchName $med $adSet $adDe }
  if($cName -eq $SENT){ $sName=$SENT; $aName=$SENT }
  else {
    if($aName -eq ''){ $aName=$SENT }
    if($aName -ne $SENT -and $adToAdset.ContainsKey($aName)){ $sName=$adToAdset[$aName] }
    else { $sName=MatchName $med $adsetSet $adsetDe; if($sName -eq ''){ $sName=$SENT } }
  }
  if($d -ne 'sem-data'){ $o=GetDay $d; $o.leads++; $o.$tier++ }
  $g=GetGrain $d $cName $sName $aName; $g.leads++; $g.$tier++
  # distribuicoes (labels = valor da planilha; front prettifica acentos)
  $espL=TitleFirst $r[$L_ESP]; $formL=TitleFirst $r[$L_FORM]; $prefL=TitleFirst $r[$L_PREF]
  $clinL= if($hasClin){'sim'} else {'nao'}
  Bump $dFatA ([string]$fatLevel); Bump $dEspA $espL; Bump $dFormA $formL; Bump $dClinA $clinL; Bump $dPrefA $prefL
  if($tier -eq 'A' -or $tier -eq 'B'){ Bump $dFatQ ([string]$fatLevel); Bump $dEspQ $espL; Bump $dFormQ $formL; Bump $dPrefQ $prefL }
  $leadRows.Add([pscustomobject]@{date=$d;tier=$tier;camp=$cName;adset=$sName;ad=$aName})
}

# ---- arrays finais -------------------------------------------------
$dailyArr=@($daily.Values | Sort-Object date)
$grainArr=@($grain.Values | Where-Object { $_.spend -gt 0 -or $_.leads -gt 0 } | Sort-Object date)
$dates=@($dailyArr | Where-Object { $_.date -match '^\d{4}-\d{2}-\d{2}$' } | ForEach-Object { $_.date } | Sort-Object)
$leadDates=@($leadRows | Where-Object { $_.date -match '^\d{4}-\d{2}-\d{2}$' } | ForEach-Object { $_.date } | Sort-Object)

function DistArr($h){ $out=@(); foreach($e in ($h.GetEnumerator()|Sort-Object Value -Descending)){ $out+=[pscustomobject]@{label=[string]$e.Key;n=[int]$e.Value} }; return ,@($out) }
function FatArr($h){ $out=@(); foreach($e in ($h.GetEnumerator()|Sort-Object {[int]$_.Key} -Descending)){ $out+=[pscustomobject]@{level=[int]$e.Key;n=[int]$e.Value} }; return ,@($out) }
function Sum0($arr,$p){ $s=($arr|Measure-Object $p -Sum).Sum; if($null -eq $s){return 0}; return $s }

$qCount=@($leadRows|Where-Object{$_.tier -eq 'A' -or $_.tier -eq 'B'}).Count
$tot=[pscustomobject]@{
  spend=(Sum0 $dailyArr 'spend'); impr=(Sum0 $dailyArr 'impr'); clicks=(Sum0 $dailyArr 'clicks'); lpv=(Sum0 $dailyArr 'lpv')
  v3=(Sum0 $dailyArr 'v3'); v75=(Sum0 $dailyArr 'v75'); metaLeads=(Sum0 $dailyArr 'metaLeads'); leads=$leadRows.Count
  A=(@($leadRows|Where-Object{$_.tier -eq 'A'}).Count); B=(@($leadRows|Where-Object{$_.tier -eq 'B'}).Count); C=(@($leadRows|Where-Object{$_.tier -eq 'C'}).Count)
  qualif=$qCount; attributed=(@($leadRows|Where-Object{$_.camp -ne $SENT}).Count); tests=$nTest
}
$paid=@($leadRows|Where-Object{$_.camp -ne $SENT}); $org=@($leadRows|Where-Object{$_.camp -eq $SENT})
$bySource=@(
  [pscustomobject]@{src='pago';leads=$paid.Count;qualif=(@($paid|Where-Object{$_.tier -eq 'A' -or $_.tier -eq 'B'}).Count)}
  [pscustomobject]@{src='organico';leads=$org.Count;qualif=(@($org|Where-Object{$_.tier -eq 'A' -or $_.tier -eq 'B'}).Count)}
)

$nowIso=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$nowBR=[System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow,'E. South America Standard Time').ToString('dd/MM/yyyy HH:mm')
$utf8=[System.Text.UTF8Encoding]::new($false)

$payload=[pscustomobject]@{
  generatedAt=$nowIso; generatedAtBR=$nowBR; taxMultiplier=$TAX; campaign='MMP-29-30AGO'
  dateMin=$(if($dates.Count){$dates[0]}else{''}); dateMax=$(if($dates.Count){$dates[-1]}else{''})
  leadDateMin=$(if($leadDates.Count){$leadDates[0]}else{''}); leadDateMax=$(if($leadDates.Count){$leadDates[-1]}else{''})
  totals=$tot; bySource=@($bySource)
  perfil=[pscustomobject]@{ fat=(FatArr $dFatA); esp=(DistArr $dEspA); formado=(DistArr $dFormA); clinica=(DistArr $dClinA); pref=(DistArr $dPrefA) }
  qualif=[pscustomobject]@{ fat=(FatArr $dFatQ); esp=(DistArr $dEspQ); formado=(DistArr $dFormQ); pref=(DistArr $dPrefQ) }
  daily=@($dailyArr); grain=@($grainArr)
}
$json=$payload | ConvertTo-Json -Depth 9 -Compress
[IO.File]::WriteAllText((Join-Path $root 'data.js'), ("window.MMP="+$json+";"), $utf8)
Write-Host ("OK  dias={0} grain={1} leadsReais={2} testes={3}  A={4} B={5} C={6}  qualif={7} attrib={8}  gasto+imp=R$ {9}" -f `
  $dailyArr.Count,$grainArr.Count,$tot.leads,$tot.tests,$tot.A,$tot.B,$tot.C,$tot.qualif,$tot.attributed,($tot.spend.ToString('N2',$BR)))
