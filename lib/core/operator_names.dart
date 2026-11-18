import 'operator_data.dart';

/// The known name of the operator that [isp] (the name a service reported) or [asn] ("AS197207") is, or null when it is no
/// operator the table knows. The number of the network decides first (it is exact), then the name.
String? operatorBrand({String? isp, String? asn}) {
  final number = int.tryParse((asn ?? '').replaceFirst(RegExp(r'^[Aa][Ss]'), '').trim());
  if (number != null) {
    for (final e in operatorTable) {
      if (e.asns.contains(number)) return e.brand;
    }
  }
  final name = (isp ?? '').toLowerCase();
  if (name.isEmpty) return null;
  for (final e in operatorTable) {
    for (final n in e.names) {
      if (name.contains(n)) return e.brand;
    }
  }
  return null;
}

/// [isp] with the known name of the operator after it, "Mobile Communication Company of Iran (MCI, Hamrah Aval)". The
/// name is left out when the table does not know the operator, and when [isp] already says it.
String? operatorLabel({String? isp, String? asn}) {
  final name = (isp ?? '').trim();
  final brand = operatorBrand(isp: name, asn: asn);
  if (name.isEmpty) return brand;
  if (brand == null) return name;
  // "Vodafone Group" needs no "(Vodafone)": the brand's first word is in the name.
  final first = brand.split(RegExp(r'[\s,(]')).first.toLowerCase();
  if (first.length >= 4 && name.toLowerCase().contains(first)) return name;
  return '$name ($brand)';
}
