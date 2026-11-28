import 'endpoints.dart';

class NativeProfile {
  const NativeProfile._(this.issuer, this.clientId, this.redirect);

  final String issuer;
  final String clientId;
  final String redirect;

  static NativeProfile? parse(String issuer, String clientId, String redirect) {
    if (issuer.length > 2048 ||
        !isHttpsOrigin(issuer) ||
        _clientId.stringMatch(clientId) != clientId ||
        redirect.length > 2048) {
      return null;
    }
    final link = Uri.tryParse(redirect);
    if (link == null ||
        link.scheme != 'https' ||
        link.host.isEmpty ||
        link.hasPort ||
        link.path.length < 2 ||
        link.path.startsWith('//') ||
        _linkPath.stringMatch(link.path) != link.path ||
        redirect != '${link.origin}${link.path}') {
      return null;
    }
    return NativeProfile._(issuer, clientId, redirect);
  }

  bool matches(Map<String, Object?> record) =>
      record['iss'] == issuer &&
      record['client_id'] == clientId &&
      record['redirect_uri'] == redirect;

  Map<String, Object?> get binding => {
    'iss': issuer,
    'client_id': clientId,
    'redirect_uri': redirect,
  };

  Uri endpoint(String path) => Uri.parse('$issuer$path');
}

final _clientId = RegExp(r'^[A-Za-z0-9._-]{1,128}$');
final _linkPath = RegExp(r'^/[A-Za-z0-9/._~-]*$');
