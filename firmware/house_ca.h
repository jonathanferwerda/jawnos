// The JawnOS house CA, as a trust anchor for the board's TLS clients.
//
// server/house-ca.pem is the CA that signs the manager's peer leaf
// (scripts/house_ca.pl), and it is gitignored because a house generates it.
// The certificate is public material - never the CA private key - so every
// board pins it here instead of accepting any peer.
//
// Keep HOUSE_CA_PEM byte-identical to server/house-ca.pem: t/282 compares them
// when the file is present, and a board carrying a stale anchor refuses every
// house connection.
#ifndef JAWNOS_HOUSE_CA_H
#define JAWNOS_HOUSE_CA_H

#define HOUSE_CA_PEM \
"-----BEGIN CERTIFICATE-----\n" \
"MIIBvjCCAWSgAwIBAgIUd6goj5FG/egbn9Dh/0RfG3bfem8wCgYIKoZIzj0EAwIw\n" \
"KzEYMBYGA1UEAwwPSmF3bk9TIEhvdXNlIENBMQ8wDQYDVQQKDAZKYXduT1MwHhcN\n" \
"MjYxMTA2MTg1NTU0WhcNMzYxMTAzMTg1NTU0WjArMRgwFgYDVQQDDA9KYXduT1Mg\n" \
"SG91c2UgQ0ExDzANBgNVBAoMBkphd25PUzBZMBMGByqGSM49AgEGCCqGSM49AwEH\n" \
"A0IABJf3WQ+zPK7ZxZY21qUb6zN+ZOcqMBBbwVqIUtlfy3hH5xgqEL80LYRNFpXp\n" \
"9NwEFBUKsQydInc8jeh5qUNhJJ6jZjBkMB8GA1UdIwQYMBaAFD+xI4Tl2+FESBRi\n" \
"Ha6WiCI71u2bMBIGA1UdEwEB/wQIMAYBAf8CAQAwDgYDVR0PAQH/BAQDAgEGMB0G\n" \
"A1UdDgQWBBQ/sSOE5dvhREgUYh2ulogiO9btmzAKBggqhkjOPQQDAgNIADBFAiEA\n" \
"hrkV1NH3Q3Jzll9pfPFhV2rJoZxj8rKF7/bW5sRGijoCIDWIiQ8Rhqg1K0nkSfFK\n" \
"4fIwUrJ1rkAiK2dkf98IC9Wr\n" \
"-----END CERTIFICATE-----\n"

#endif
