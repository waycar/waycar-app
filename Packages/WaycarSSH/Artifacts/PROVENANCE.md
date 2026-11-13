# Native artifact provenance

- libssh2: c7557852f1b7c0d3b9cffd5390eb33fdf93fb17f, tag master-c755785, commit c7557852f1b7c0d3b9cffd5390eb33fdf93fb17f
- libssh2 patch: 0001-userauth-publickey-skip-pk-ok-query.patch sha256 fe561687e186392d9b5adcacebd1cd6bcce0156cf3baae20982dab3d30bbe42d
- libssh2 patch: 0002-channel-pty-and-process-request-back-to-back.patch sha256 53befb159f1110a495e317d2e9e73126bbd46a7943a519bfca3f1737fa3de2ed
- libssh2 patch: 0003-packet-requirev-skip-other-channel-replies.patch sha256 994104e172c70c65c5a24be49697f93ad08223f80552e5f3375bcf3f86751638
- libssh2 patch: 0004-channel-pipelined-opens.patch sha256 5d9180c37def00d54c7e9a8d6dfacadc37292a9fec89b9f6a50e52de9ff82f8c
- OpenSSL: 3.6.3, tag openssl-3.6.3, commit aae016bfd52fcad2bc9657c2c782cfdf73b1ed5f
- Xcode: Xcode 27.0;Build version 27A266a
- Compiler: Apple clang version 21.0.0 (clang-2100.3.34.2)
- iPhoneOS SDK: 27.0
- iPhone Simulator SDK: 27.0
- Deployment target: iOS 18.0
- Configuration: Release, static libraries, arm64 device and arm64 Simulator
- OpenSSL features: no shared library, module, legacy provider, deprecated API, DSA, RC2, RC4, DES, CAST, Blowfish, IDEA, SEED, Camellia, ARIA, SM2, SM3, SM4, Whirlpool, or RIPEMD-160
- OpenSSL privacy manifest: upstream os-dep/Apple/PrivacyInfo.xcprivacy
- libssh2 crypto backend: OpenSSL; MD5, RIPEMD, RSA-SHA1, SHA-1 KEX/MACs,
  Blowfish, RC4, CAST, 3DES, and CBC are off (upstream defaults and
  LIBSSH2_NO_AES_CBC); ML-KEM hybrid key exchanges available
- Build command: make ssh-artifacts
