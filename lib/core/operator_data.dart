// The operators the app shows a known name for: 173 operators, with their ASNs and the pieces of the names
// they are registered under. Made from research (every ASN checked against its holder in RIPEstat), by
// tools/make_operator_data.dart; do not edit by hand.

/// An operator (a mobile network or an internet provider) by the names the services report it under, and the name people know
/// it by.
class OperatorEntry {
  const OperatorEntry(this.brand, {this.asns = const [], this.names = const []});

  /// The name people know it by, in Latin letters ("Irancell").
  final String brand;

  /// The numbers of its networks (197207), exact.
  final List<int> asns;

  /// Lower-case pieces of the name it is registered under, each one only that company's.
  final List<String> names;
}

const operatorTable = <OperatorEntry>[
  // IR
  OperatorEntry('Asiatech', asns: [43754, 211421, 60077, 51433, 203000], names: ['asiatech data transmission', 'asre dadeha asiatech']),
  OperatorEntry('DCI (Data Comm. of Iran)', asns: [12880, 60148], names: ['iran information technology company']),
  OperatorEntry('FANAP Telecom', asns: [24631, 206065, 203558], names: ['pasargad arian']),
  OperatorEntry('HiWeb', asns: [56402], names: ['dadeh gostar asr novin']),
  OperatorEntry('Irancell', asns: [44244], names: ['iran cell service and communication', 'irancell']),
  OperatorEntry('ITRC (Telecom Research)', asns: [57292], names: ['iran telecommunications research center', 'ict research institute']),
  OperatorEntry('MCI, Hamrah Aval', asns: [197207], names: ['mobile communication company of iran']),
  OperatorEntry('Mobinnet', asns: [50810, 47330], names: ['mobin net communication']),
  OperatorEntry('Pars Online', asns: [16322, 60976, 61061], names: ['parsan lin']),
  OperatorEntry('Pishgaman', asns: [49100, 34918, 3263, 201540, 201015], names: ['pishgaman toseeh ertebatat', 'pishgaman toseeh fanavari etelaat']),
  OperatorEntry('Rightel', asns: [57218, 62140], names: ['rightel communication service']),
  OperatorEntry('Sabanet', asns: [39501], names: ['parvaresh dadeha']),
  OperatorEntry('Shatel', asns: [31549], names: ['aria shatel']),
  OperatorEntry('Shatel Mobile', asns: [34369]),
  OperatorEntry('TCI (Mokhaberat)', asns: [58224], names: ['iran telecommunication company']),
  OperatorEntry('TIC (TCI backbone)', asns: [48159, 49666], names: ['telecommunication infrastructure company']),
  // AE
  OperatorEntry('du', asns: [15802], names: ['emirates integrated telecommunications']),
  OperatorEntry('Etisalat (e&)', asns: [5384, 8966], names: ['emirates telecommunications group', 'emirates telecommunications corporation']),
  // AF
  OperatorEntry('AWCC', asns: [38742], names: ['afghan wireless communication company']),
  OperatorEntry('Roshan', asns: [45178]),
  // AR
  OperatorEntry('Movistar (Telefonica)', asns: [22927], names: ['telefonica de argentina']),
  // AT
  OperatorEntry('Drei (Three AT)', asns: [25255], names: ['hutchison drei austria']),
  OperatorEntry('Magenta (T-Mobile AT)', asns: [8412], names: ['t-mobile austria']),
  // AU
  OperatorEntry('Optus', asns: [4804], names: ['microplex']),
  // AZ
  OperatorEntry('Nar', asns: [42779], names: ['azerfon']),
  // BA
  OperatorEntry('HT Eronet', asns: [20875], names: ['jp ht d.d. mostar']),
  OperatorEntry('m:tel (Telekom Srpske)', asns: [25144], names: ['telekomunikacije republike srpske']),
  // BD
  OperatorEntry('Robi', asns: [24432], names: ['tm international bangladesh']),
  // BG
  OperatorEntry('Yettel Bulgaria', asns: [29244], names: ['cetin bulgaria']),
  // BH
  OperatorEntry('Batelco (Beyon)', asns: [5416], names: ['beyon b.s.c.']),
  // BJ
  OperatorEntry('MTN Benin', asns: [37424], names: ['spacetel benin']),
  // BO
  OperatorEntry('Entel Bolivia', asns: [6568], names: ['empresa nacional de telecomunicaciones']),
  OperatorEntry('Tigo Bolivia', asns: [27882], names: ['telefonica celular de bolivia']),
  OperatorEntry('Viva Bolivia', asns: [28024], names: ['nuevatel pcs de bolivia']),
  // BR
  OperatorEntry('Claro Brasil', asns: [28573, 22085, 4230], names: ['claro nxt telecomunicacoes', 'claro s/a', 'claro s.a.']),
  OperatorEntry('Vivo', asns: [26599, 27699, 18881], names: ['telefonica brasil']),
  // BY
  OperatorEntry('A1 Belarus', asns: [42772], names: ['unitary enterprise a1']),
  OperatorEntry('Beltelecom (ByFly)', asns: [6697], names: ['republican unitary telecommunication enterprise beltelecom']),
  OperatorEntry('MTS Belarus', asns: [25106], names: ['mobile telesystems jllc']),
  // CD
  OperatorEntry('Airtel DRC', asns: [37020], names: ['celtel drc']),
  // CI
  OperatorEntry('Moov Africa CI', asns: [37190], names: ['atlantique telecom (cote d\'ivoire)']),
  // CL
  OperatorEntry('Movistar Chile', asns: [7418], names: ['telefonica chile']),
  // CN
  OperatorEntry('China Telecom (ChinaNet)', asns: [4134, 4812], names: ['chinanet', 'china telecom (group)']),
  // CO
  OperatorEntry('Claro Colombia', asns: [10620, 26611], names: ['telmex colombia', 'comunicacion celular s.a. comcel']),
  OperatorEntry('Movistar Colombia', asns: [3816], names: ['colombia telecomunicaciones s.a. esp']),
  OperatorEntry('Tigo UNE', asns: [13489], names: ['une epm telecomunicaciones']),
  // CR
  OperatorEntry('ICE (Kolbi)', asns: [11830], names: ['instituto costarricense de electricidad']),
  OperatorEntry('Movistar Costa Rica', asns: [262202], names: ['telefonica de costa rica']),
  OperatorEntry('Tigo Costa Rica', asns: [262197], names: ['millicom cable costa rica']),
  // CU
  OperatorEntry('ETECSA (Cubacel)', asns: [27725], names: ['empresa de telecomunicaciones de cuba']),
  // CY
  OperatorEntry('Cyta', asns: [6866], names: ['cyprus telecommunications authority']),
  // DE
  OperatorEntry('O2 (Telefonica DE)', asns: [6805], names: ['telefonica germany']),
  OperatorEntry('Telekom', asns: [3320], names: ['deutsche telekom']),
  // DK
  OperatorEntry('Norlys (ex-Telia DK)', asns: [3308], names: ['norlys telco']),
  // DO
  OperatorEntry('Claro Dominicana', asns: [6400], names: ['compania dominicana de telefonos']),
  // DZ
  OperatorEntry('Djezzy', asns: [327931], names: ['optimum telecom algeria']),
  OperatorEntry('Ooredoo Algeria', asns: [33779], names: ['wataniya telecom algerie']),
  // EC
  OperatorEntry('Claro Ecuador', asns: [23487, 27738], names: ['conecel', 'ecuadortelecom']),
  OperatorEntry('Movistar Ecuador', asns: [7315], names: ['otecel']),
  // EG
  OperatorEntry('Orange Egypt', asns: [37069], names: ['egyptian company for mobile services']),
  OperatorEntry('Telecom Egypt (WE)', asns: [8452]),
  // ES
  OperatorEntry('Movistar', asns: [3352], names: ['telefonica de espana']),
  // GB
  OperatorEntry('BT', asns: [2856], names: ['british telecommunications']),
  OperatorEntry('O2 UK (Telefonica UK)', asns: [35228], names: ['telefonica uk']),
  OperatorEntry('Plusnet', asns: [6871]),
  OperatorEntry('Three UK', asns: [206067], names: ['hutchison 3g uk']),
  // GH
  OperatorEntry('MTN Ghana', asns: [30986], names: ['scancom limited']),
  OperatorEntry('Vodafone Ghana', asns: [29614], names: ['ghana telecommunications company']),
  // GR
  OperatorEntry('Nova (Wind Hellas)', asns: [25472, 1241], names: ['nova telecommunications & media']),
  OperatorEntry('OTE (Cosmote)', asns: [6799, 29247], names: ['ote sa (hellenic telecommunications']),
  // GT
  OperatorEntry('Claro Guatemala', asns: [23243], names: ['comcel guatemala']),
  OperatorEntry('Tigo (Millicom)', asns: [14754], names: ['telecomunicaciones de guatemala']),
  // HK
  OperatorEntry('3 Hong Kong', asns: [10118], names: ['hutchison telephone company']),
  // ID
  OperatorEntry('MyRepublic Indonesia', asns: [63859], names: ['eka mas republik']),
  OperatorEntry('Telkom (IndiHome)', asns: [7713], names: ['telekomunikasi indonesia']),
  OperatorEntry('Telkomsel', asns: [23693], names: ['telekomunikasi selular']),
  // IE
  OperatorEntry('eir', asns: [5466, 15751], names: ['eircom']),
  // IL
  OperatorEntry('HOT', asns: [12849], names: ['hot-net internet services']),
  OperatorEntry('Netvision (Cellcom)', asns: [1680], names: ['cellcom fixed line communication']),
  OperatorEntry('Partner', asns: [12400], names: ['partner communications ltd']),
  // IN
  OperatorEntry('ACT Fibernet', asns: [24309], names: ['atria convergence technologies']),
  OperatorEntry('BSNL', asns: [9829], names: ['bharat sanchar nigam']),
  // IQ
  OperatorEntry('Zain Iraq', asns: [59588], names: ['al atheer telecommunication']),
  // IT
  OperatorEntry('TIM (Telecom Italia)', asns: [3269, 16232], names: ['telecom italia s.p.a.']),
  OperatorEntry('WindTre', asns: [1267], names: ['wind tre']),
  // JO
  OperatorEntry('Orange Jordan', asns: [8697], names: ['jordan telecommunications psc']),
  OperatorEntry('Umniah', asns: [9038], names: ['al bahrainia al urdunia']),
  OperatorEntry('Zain Jordan', asns: [48832], names: ['jordanian mobile phone services']),
  // JP
  OperatorEntry('OCN (NTT Docomo Biz)', asns: [4713], names: ['ntt docomo business', 'ntt communications']),
  // KG
  OperatorEntry('Beeline KG (Sky Mobile)', asns: [41329]),
  OperatorEntry('MegaCom (Alfa Telecom)', asns: [50223], names: ['alfa telecom cjsc']),
  OperatorEntry('O! (Nur Telecom)', asns: [47237, 50251], names: ['nur telecom']),
  // KH
  OperatorEntry('Cellcard', asns: [17976], names: ['camgsm company']),
  OperatorEntry('Metfone (Viettel)', asns: [38623]),
  // KR
  OperatorEntry('KT', asns: [4766], names: ['korea telecom']),
  OperatorEntry('LG U+', asns: [17858, 17853, 3786, 9316], names: ['lg powercomm', 'lgtelecom', 'lg dacom']),
  // KW
  OperatorEntry('Ooredoo Kuwait', asns: [29357], names: ['national mobile telecommunications company']),
  OperatorEntry('stc Kuwait', asns: [47589], names: ['kuwait telecommunications company']),
  OperatorEntry('Zain Kuwait', asns: [42961]),
  // KZ
  OperatorEntry('Beeline Kazakhstan', asns: [206026, 21299], names: ['kar-tel llc']),
  OperatorEntry('Tele2/Altel Kazakhstan', asns: [48503, 29555], names: ['mobile telecom-service llp']),
  // LB
  OperatorEntry('Alfa Lebanon', asns: [57513], names: ['mobile interim company 1']),
  OperatorEntry('Touch Lebanon', asns: [38999], names: ['mobile interim company no.2']),
  // MA
  OperatorEntry('Orange Maroc (Meditel)', asns: [36925], names: ['meditelecom']),
  // ME
  OperatorEntry('m:tel Montenegro', asns: [43940]),
  // MG
  OperatorEntry('Telma', asns: [37054], names: ['telecom malagasy']),
  // ML
  OperatorEntry('Malitel (Sotelma)', asns: [21271], names: ['society of mali\'s telecommunications']),
  // MM
  OperatorEntry('MPT', asns: [9988], names: ['myanma posts and telecommunications']),
  OperatorEntry('Mytel', asns: [136255], names: ['telecom international myanmar']),
  // MO
  OperatorEntry('CTM', asns: [4609], names: ['companhia de telecomunicacoes de macau']),
  // MV
  OperatorEntry('Dhiraagu', asns: [7642], names: ['dhivehi raajjeyge gulhun']),
  // MW
  OperatorEntry('TNM', asns: [37294], names: ['telekom networks malawi']),
  // MX
  OperatorEntry('Izzi (Televisa)', asns: [28548], names: ['cablevision, s.a. de c.v.']),
  OperatorEntry('Telcel', asns: [28403], names: ['radiomovil dipsa']),
  OperatorEntry('Telmex (Infinitum)', asns: [8151]),
  // MY
  OperatorEntry('Maxis', asns: [9534], names: ['binariang berhad']),
  OperatorEntry('Unifi (Telekom Malaysia)', asns: [4788], names: ['tm technology services']),
  // NL
  OperatorEntry('VodafoneZiggo', asns: [33915], names: ['vodafone libertel']),
  // NO
  OperatorEntry('Altibox', asns: [29695, 203995], names: ['lyse tele']),
  // NZ
  OperatorEntry('2degrees', asns: [9790], names: ['two degrees networks']),
  // OM
  OperatorEntry('Omantel', asns: [28885], names: ['oman telecommunications company']),
  OperatorEntry('Ooredoo Oman', asns: [50010], names: ['omani qatari telecommunication']),
  OperatorEntry('Vodafone Oman', asns: [212661], names: ['oman future telecommunications']),
  // PE
  OperatorEntry('Bitel', asns: [262210], names: ['viettel peru']),
  OperatorEntry('Claro Peru', asns: [12252], names: ['america movil peru']),
  OperatorEntry('Movistar Peru', asns: [6147], names: ['integratel peru']),
  // PH
  OperatorEntry('PLDT', asns: [9299], names: ['philippine long distance telephone']),
  // PK
  OperatorEntry('Jazz (Mobilink)', asns: [45669]),
  OperatorEntry('PTCL', asns: [17557], names: ['pakistan telecommunication company']),
  OperatorEntry('Zong (CMPak)', asns: [59257], names: ['cmpak limited']),
  // PL
  OperatorEntry('Play', asns: [39603, 9141], names: ['p4 sp. z o.o.']),
  OperatorEntry('Plus (Polkomtel)', asns: [8374], names: ['polkomtel']),
  // PR
  OperatorEntry('Claro Puerto Rico', asns: [10396], names: ['datacom caribe']),
  // PY
  OperatorEntry('Personal Paraguay', asns: [27895], names: ['nucleo s.a.']),
  OperatorEntry('Tigo Paraguay', asns: [23201], names: ['telecel s.a.']),
  // RU
  OperatorEntry('Beeline Russia', asns: [3216, 16345], names: ['vimpelcom']),
  OperatorEntry('Dom.ru (ER-Telecom)', asns: [9049], names: ['er-telecom holding']),
  OperatorEntry('MGTS', asns: [25513], names: ['moscow city telephone network']),
  OperatorEntry('MTS', asns: [8359], names: ['mts pjsc', 'mobile telesystems pjsc']),
  OperatorEntry('T2 (Tele2 Russia)', asns: [41330], names: ['t2 mobile']),
  // SA
  OperatorEntry('Mobily', asns: [35819], names: ['etihad etisalat']),
  OperatorEntry('STC', asns: [39891, 25019], names: ['saudi telecom company']),
  OperatorEntry('Zain KSA', asns: [43766], names: ['mobile telecommunication company saudi arabia']),
  // SE
  OperatorEntry('3 (Hi3G)', asns: [44034], names: ['hi3g access']),
  // SG
  OperatorEntry('M1', asns: [4773], names: ['mobileone ltd']),
  // SN
  OperatorEntry('Orange Sonatel', asns: [8346]),
  // SY
  OperatorEntry('STE (Syrian Telecom)', asns: [29256, 201550], names: ['syrian telecommunication private closed joint stock']),
  // TH
  OperatorEntry('3BB', asns: [45758], names: ['triple t broadband']),
  OperatorEntry('AIS', asns: [131445], names: ['advance wireless network']),
  OperatorEntry('dtac', asns: [24378], names: ['total access communication']),
  OperatorEntry('NT (ex-TOT)', asns: [23969], names: ['tot public company']),
  // TR
  OperatorEntry('Turk Telekom', asns: [9121], names: ['turk telekomunikasyon']),
  OperatorEntry('Turk Telekom Mobile', asns: [20978], names: ['tt mobil iletisim']),
  OperatorEntry('Turkcell Superonline', asns: [34984], names: ['superonline iletisim']),
  // TT
  OperatorEntry('Flow (Columbus)', asns: [27665], names: ['columbus communications trinidad']),
  OperatorEntry('TSTT (bmobile)', asns: [5639], names: ['telecommunication services of trinidad and tobago']),
  // TW
  OperatorEntry('Chunghwa (HiNet)', asns: [3462, 17421], names: ['chunghwa telecom']),
  // TZ
  OperatorEntry('Halotel (Viettel)', asns: [327885], names: ['viettel tanzania']),
  OperatorEntry('Yas (ex-Tigo)', asns: [37035], names: ['mic tanzania']),
  // UA
  OperatorEntry('Vodafone Ukraine', asns: [21497], names: ['vf ukraine']),
  // US
  OperatorEntry('CenturyLink (Lumen)', asns: [209, 22561], names: ['centurylink communications']),
  OperatorEntry('Optimum (Altice)', asns: [6128], names: ['cablevision systems corp']),
  OperatorEntry('Spectrum (Charter)', asns: [20115, 11426, 10796, 12271, 11351, 20001, 33363, 7843, 11427], names: ['charter communications', 'time warner cable internet']),
  OperatorEntry('Starlink', asns: [14593], names: ['space exploration technologies']),
  OperatorEntry('Verizon Wireless', asns: [6167, 22394], names: ['cellco partnership']),
  OperatorEntry('Xfinity (Comcast)', asns: [7922, 7015, 7725, 33651, 33657, 33650, 33490, 20214, 33668, 22909, 33287, 21508, 13367, 33662, 33667, 33652, 33660], names: ['comcast cable communications']),
  // UY
  OperatorEntry('Antel', asns: [6057], names: ['administracion nacional de telecomunicaciones']),
  // UZ
  OperatorEntry('Beeline Uzbekistan', asns: [41202], names: ['unitel llc']),
  OperatorEntry('Mobiuz', asns: [64466], names: ['universal mobile systems']),
  OperatorEntry('Ucell (Coscom)', asns: [49273], names: ['coscom liability limited company']),
  // VE
  OperatorEntry('Inter (Telemic)', asns: [21826], names: ['corporacion telemic']),
  OperatorEntry('Movistar Venezuela', asns: [6306], names: ['telefonica venezolana']),
  // YE
  OperatorEntry('YemenNet', asns: [30873], names: ['public telecommunication corporation']),
];
