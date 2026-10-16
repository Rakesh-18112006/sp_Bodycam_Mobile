// Throw-away EC P-256 key pairs generated ONLY for these tests. Not used anywhere else; never a real signing key.
const String trustedPrivatePem = '''-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIMaJPR3itV0pvhCdVyJKPRkL03vQRdeyR8D7DpF1LU9PoAoGCCqGSM49
AwEHoUQDQgAEVIaWb06HapucI2TtnnaCV++/AP089u+yxHJ8k7jdddoJqC1NW5Ql
z2IW59/Zu+ZJn2NFCs1sy8B9s62Re8vpVQ==
-----END EC PRIVATE KEY-----
''';
const String trustedPublicPem = '''-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEVIaWb06HapucI2TtnnaCV++/AP08
9u+yxHJ8k7jdddoJqC1NW5Qlz2IW59/Zu+ZJn2NFCs1sy8B9s62Re8vpVQ==
-----END PUBLIC KEY-----
''';
const String otherPrivatePem = '''-----BEGIN EC PRIVATE KEY-----
MHcCAQEEINMPBwPJbGmxpJmoLY/Wqpv4aRkBkhmBpSfoinQ2wghaoAoGCCqGSM49
AwEHoUQDQgAEeDBQ3UVN2PIBnf7Q5bkxXcCcTu2yTPOkhJHdV6QAbwu9Km77Wwst
yAEYN0+7NYRiTQr8uBExoduTH5NT9rwLww==
-----END EC PRIVATE KEY-----
''';
const String otherPublicPem = '''-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEeDBQ3UVN2PIBnf7Q5bkxXcCcTu2y
TPOkhJHdV6QAbwu9Km77WwstyAEYN0+7NYRiTQr8uBExoduTH5NT9rwLww==
-----END PUBLIC KEY-----
''';
