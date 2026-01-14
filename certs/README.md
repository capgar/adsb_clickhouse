## CERT/KEY NOTES

# Expected PEM files (Cloudflare, etc)
tls.crt (site cert)
tls.key (site key)

# Download Origin CA Intermediate
example:
curl -o ca.crt https://developers.cloudflare.com/ssl/static/origin_ca_rsa_root.pem

# Create CA for self-signed client cert
openssl req -x509 -newkey rsa:2048 -keyout my-ca.key -out my-ca.crt -days 365 -nodes \
  -subj "/C=US/ST=Maryland/O=Homelab/CN=Homelab-CA"

# create server cert chain
cat tls.crt ca.crt > server_fullchain.pem
# convert to PKCS12
openssl pkcs12 -export -in server_fullchain.pem -inkey tls.key -out server.p12 -name lab.apgar.us -password pass:changeit
# create Kafka keystore
keytool -importkeystore -srckeystore server.p12 -srcstoretype PKCS12 -srcstorepass changeit -destkeystore server.keystore.jks -deststoretype JKS -deststorepass changeit

# Create truststore with server Origin CA
keytool -import -trustcacerts -alias cloudflare-origin-ca   -file ca.crt   -keystore server.truststore.jks -storepass changeit -noprompt
# Import my CA
keytool -import -trustcacerts -alias homelab-ca -file my-ca.crt -keystore server.truststore.jks -storepass changeit -noprompt
# verify both
keytool -list -keystore server.truststore.jks -storepass changeit

# Generate Clickhouse client key
openssl genrsa -out client.key 2048
# create csr
openssl req -new -key client.key -out client.csr -subj "/C=US/ST=Maryland/O=Homelab/CN=clickhouse-client"
# sign with CA
openssl x509 -req -in client.csr -CA my-ca.crt -CAkey my-ca.key \
  -CAcreateserial -out client.crt -days 365
# verify cert
openssl x509 -in client.crt -noout -issuer -subject

# Encode Keystores for Kafka Secrets
base64 -w 0 server.truststore.jks > server.truststore.jks.b64
base64 -w 0 server.keystore.jks > server.keystore.jks.b64

# Encode PEM files for ClickHouse Secrets
base64 -w 0 ca.crt > ca.crt.b64
base64 -w 0 client.crt > client.crt.b64
base64 -w 0 client.key > client.key.b64

# testing that Kafka can read its keystores
chris@chris-thinkpad:~/projects/adsb_v4/certs$ kubectl exec -n kafka kafka-0 -- ls -la /etc/kafka/secrets/
total 4
drwxrwxrwt 3 root    root  120 Jan 14 02:24 .
drwxrwxr-x 1 appuser root 4096 Oct 26  2024 ..
drwxr-xr-x 2 root    root   80 Jan 14 02:24 ..2026_01_14_02_24_29.3563563582
lrwxrwxrwx 1 root    root   32 Jan 14 02:24 ..data -> ..2026_01_14_02_24_29.3563563582
lrwxrwxrwx 1 root    root   26 Jan 14 02:24 server.keystore.jks -> ..data/server.keystore.jks
lrwxrwxrwx 1 root    root   28 Jan 14 02:24 server.truststore.jks -> ..data/server.truststore.jks

chris@chris-thinkpad:~/projects/adsb_v4/certs$ kubectl exec -n kafka kafka-0 -- keytool -list -keystore /etc/kafka/secrets/server.keystore.jks -storepass changeit
Keystore type: JKS
Keystore provider: SUN

Your keystore contains 1 entry

lab.apgar.us, Jan 14, 2026, PrivateKeyEntry, 
Certificate fingerprint (SHA-256): <snip>

Warning:
The JKS keystore uses a proprietary format. It is recommended to migrate to PKCS12 which is an industry standard format using "keytool -importkeystore -srckeystore /etc/kafka/secrets/server.keystore.jks -destkeystore /etc/kafka/secrets/server.keystore.jks -deststoretype pkcs12".

chris@chris-thinkpad:~/projects/adsb_v4/certs$ kubectl exec -n kafka kafka-0 -- keytool -list -keystore /etc/kafka/secrets/server.truststore.jks -storepass changeit
Keystore type: PKCS12
Keystore provider: SUN

Your keystore contains 1 entry

cloudflare-ca, Jan 14, 2026, trustedCertEntry, 
Certificate fingerprint (SHA-256): <snip>


# enable & kafka debug logs
            - name: KAFKA_HEAP_OPTS
              value: "-Djavax.net.debug=ssl:handshake"

kubectl logs -n kafka kafka-0 -f | grep -i "ssl\|handshake\|cert"


# check Clickhouse client cert
kubectl exec -n clickhouse chi-adsb-data-adsb-data-0-0-0 -- openssl x509 -in /etc/clickhouse-kafka-tls/client.crt -noout -issuer -subject
Defaulted container "clickhouse" out of: clickhouse, clickhouse-log
issuer=C = US, ST = California, L = San Francisco, O = "Cloudflare, Inc.", OU = www.cloudflare.com, CN = Managed CA a7b7ffbeeb281e8fbbb38475db5bddb6
subject=C = US, CN = Cloudflare

# compare to Kafka's truststore
kubectl exec -n kafka kafka-0 -- keytool -list -v -keystore /etc/kafka/secrets/server.truststore.jks -storepass changeit | grep -A5 "Owner:"
Owner: ST=California, L=San Francisco, OU=CloudFlare Origin SSL Certificate Authority, O="CloudFlare, Inc.", C=US
Issuer: ST=California, L=San Francisco, OU=CloudFlare Origin SSL Certificate Authority, O="CloudFlare, Inc.", C=US
Serial number: feace49d4c67c67
Valid from: Fri Aug 23 21:08:00 GMT 2019 until: Wed Aug 15 17:00:00 GMT 2029
Certificate fingerprints:
	 SHA1: AC:82:43:DF:EB:C7:CE:60:5C:6C:54:B5:13:29:58:ED:45:8C:C4:5C
