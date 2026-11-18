/// The city of a Cloudflare data center by its code (the letters at the end of the `CF-RAY` header and the `colo` of
/// `/cdn-cgi/trace`: the code of the airport of the city), for the data centers that carry most of the world's traffic. A code
/// that is not here is shown as it is.
const cloudflareCities = <String, String>{
  // Europe
  'AMS': 'Amsterdam', 'ARN': 'Stockholm', 'ATH': 'Athens', 'BCN': 'Barcelona', 'BEG': 'Belgrade', 'BER': 'Berlin',
  'BRU': 'Brussels', 'BTS': 'Bratislava', 'BUD': 'Budapest', 'CDG': 'Paris', 'CPH': 'Copenhagen', 'DUB': 'Dublin',
  'DUS': 'Düsseldorf', 'EDI': 'Edinburgh', 'FCO': 'Rome', 'FRA': 'Frankfurt', 'GVA': 'Geneva', 'HAM': 'Hamburg',
  'HEL': 'Helsinki', 'IST': 'Istanbul', 'KBP': 'Kyiv', 'LHR': 'London', 'LIS': 'Lisbon', 'LUX': 'Luxembourg',
  'MAD': 'Madrid', 'MAN': 'Manchester', 'MRS': 'Marseille', 'MUC': 'Munich', 'MXP': 'Milan', 'OSL': 'Oslo',
  'OTP': 'Bucharest', 'PRG': 'Prague', 'RIX': 'Riga', 'SOF': 'Sofia', 'TLL': 'Tallinn', 'VIE': 'Vienna',
  'VNO': 'Vilnius', 'WAW': 'Warsaw', 'ZAG': 'Zagreb', 'ZRH': 'Zurich', 'SVO': 'Moscow', 'LED': 'Saint Petersburg',
  // Middle East and Central Asia
  'AMM': 'Amman', 'AUH': 'Abu Dhabi', 'BAH': 'Manama', 'BGW': 'Baghdad', 'BEY': 'Beirut', 'DOH': 'Doha',
  'DXB': 'Dubai', 'FJR': 'Fujairah', 'KWI': 'Kuwait City', 'MCT': 'Muscat', 'RUH': 'Riyadh', 'JED': 'Jeddah',
  'TLV': 'Tel Aviv', 'EVN': 'Yerevan', 'TBS': 'Tbilisi', 'GYD': 'Baku', 'ALA': 'Almaty', 'TAS': 'Tashkent',
  'KBL': 'Kabul', 'ISB': 'Islamabad', 'KHI': 'Karachi', 'LHE': 'Lahore', 'EBL': 'Erbil', 'BSR': 'Basra',
  // South and East Asia
  'BLR': 'Bengaluru', 'BOM': 'Mumbai', 'CCU': 'Kolkata', 'DAC': 'Dhaka', 'DEL': 'New Delhi', 'HYD': 'Hyderabad',
  'MAA': 'Chennai', 'CMB': 'Colombo', 'KTM': 'Kathmandu', 'BKK': 'Bangkok', 'CGK': 'Jakarta', 'KUL': 'Kuala Lumpur',
  'MNL': 'Manila', 'SGN': 'Ho Chi Minh City', 'HAN': 'Hanoi', 'SIN': 'Singapore', 'HKG': 'Hong Kong', 'TPE': 'Taipei',
  'ICN': 'Seoul', 'NRT': 'Tokyo', 'HND': 'Tokyo', 'KIX': 'Osaka', 'FUK': 'Fukuoka', 'OKA': 'Naha',
  // Oceania
  'SYD': 'Sydney', 'MEL': 'Melbourne', 'BNE': 'Brisbane', 'PER': 'Perth', 'AKL': 'Auckland', 'ADL': 'Adelaide',
  // Africa
  'CAI': 'Cairo', 'JNB': 'Johannesburg', 'CPT': 'Cape Town', 'DUR': 'Durban', 'LOS': 'Lagos', 'NBO': 'Nairobi',
  'ACC': 'Accra', 'CMN': 'Casablanca', 'ALG': 'Algiers', 'TUN': 'Tunis', 'DAR': 'Dar es Salaam', 'ADD': 'Addis Ababa',
  'MBA': 'Mombasa', 'LAD': 'Luanda', 'MPM': 'Maputo',
  // North America
  'ATL': 'Atlanta', 'BOS': 'Boston', 'BUF': 'Buffalo', 'CLT': 'Charlotte', 'DEN': 'Denver', 'DFW': 'Dallas',
  'DTW': 'Detroit', 'EWR': 'Newark', 'HNL': 'Honolulu', 'HOU': 'Houston', 'IAD': 'Ashburn', 'IAH': 'Houston',
  'JAX': 'Jacksonville', 'JFK': 'New York', 'LAS': 'Las Vegas', 'LAX': 'Los Angeles', 'MCI': 'Kansas City',
  'MIA': 'Miami', 'MSP': 'Minneapolis', 'OMA': 'Omaha', 'ORD': 'Chicago', 'PDX': 'Portland', 'PHL': 'Philadelphia',
  'PHX': 'Phoenix', 'PIT': 'Pittsburgh', 'RDU': 'Raleigh', 'SAN': 'San Diego', 'SEA': 'Seattle', 'SJC': 'San Jose',
  'SLC': 'Salt Lake City', 'SMF': 'Sacramento', 'STL': 'St. Louis', 'TPA': 'Tampa', 'YUL': 'Montréal',
  'YVR': 'Vancouver', 'YYC': 'Calgary', 'YYZ': 'Toronto', 'YOW': 'Ottawa', 'YWG': 'Winnipeg', 'MEX': 'Mexico City',
  'QRO': 'Querétaro', 'GDL': 'Guadalajara', 'PTY': 'Panama City', 'SJO': 'San José', 'GUA': 'Guatemala City',
  'KIN': 'Kingston', 'SDQ': 'Santo Domingo', 'SJU': 'San Juan',
  // South America
  'GRU': 'São Paulo', 'GIG': 'Rio de Janeiro', 'BSB': 'Brasília', 'CWB': 'Curitiba', 'POA': 'Porto Alegre',
  'FOR': 'Fortaleza', 'EZE': 'Buenos Aires', 'SCL': 'Santiago', 'LIM': 'Lima', 'BOG': 'Bogotá', 'UIO': 'Quito',
  'MVD': 'Montevideo', 'ASU': 'Asunción', 'CCS': 'Caracas',
};

/// The code of the data center in a `CF-RAY` header ("a5c788ec2d54d19f-MCI"), upper case, or null.
String? coloOfRay(String? ray) {
  final m = RegExp(r'-([A-Za-z]{3})$').firstMatch((ray ?? '').trim());
  return m?.group(1)?.toUpperCase();
}

/// The `colo` line of a `/cdn-cgi/trace` body, upper case, or null.
String? coloOfTrace(String body) {
  final m = RegExp(r'^colo=([A-Za-z]{3})\s*$', multiLine: true).firstMatch(body);
  return m?.group(1)?.toUpperCase();
}

/// "Frankfurt (FRA)", or just "FRA" for a code the table has no city for.
String coloLabel(String code) {
  final city = cloudflareCities[code.toUpperCase()];
  return city == null ? code.toUpperCase() : '$city (${code.toUpperCase()})';
}
