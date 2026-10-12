/// Removes values that must never leave the device in logs or crash reports:
/// API hashes, auth/session tokens, phone numbers and long digit/hex secrets.
String redactSecrets(String input) {
  var text = input;
  for (final pattern in _patterns) {
    text = text.replaceAllMapped(pattern, (m) => '${m.group(1) ?? ''}[REDACTED]');
  }
  return text;
}

final _patterns = <RegExp>[
  RegExp(r'((?:api_hash|apiHash|token|secret|password|auth_key|database_encryption_key)["\x27]?\s*[:=]\s*["\x27]?)[^\s"\x27,}]+', caseSensitive: false),
  RegExp(r'(\+?)\d{9,15}\b'),
  RegExp(r'()\b[0-9a-f]{32,}\b', caseSensitive: false),
];
