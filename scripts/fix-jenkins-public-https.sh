#!/usr/bin/env bash
# Run on Jenkins (172.17.105.16) — fixes https://45.114.84.54 access
set -euo pipefail

PUBLIC_IP="${1:-45.114.84.54}"
PRIVATE_IP="${2:-172.17.105.16}"
SSL_DIR=/etc/nginx/ssl/jenkins

echo "=== TLS cert: ${PUBLIC_IP} + ${PRIVATE_IP} ==="
sudo mkdir -p "${SSL_DIR}"
sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout "${SSL_DIR}/jenkins.key" \
  -out "${SSL_DIR}/jenkins.crt" \
  -subj "/CN=${PUBLIC_IP}" \
  -addext "subjectAltName=IP:${PRIVATE_IP},IP:${PUBLIC_IP}"
sudo chmod 600 "${SSL_DIR}/jenkins.key"
sudo openssl x509 -in "${SSL_DIR}/jenkins.crt" -noout -ext subjectAltName

echo ""
echo "=== Jenkins URL -> https://${PUBLIC_IP}/ ==="
sudo tee /var/lib/jenkins/init.groovy.d/10-https-url.groovy >/dev/null <<EOF
import jenkins.model.JenkinsLocationConfiguration

def location = JenkinsLocationConfiguration.get()
def targetUrl = "https://${PUBLIC_IP}/"
if (location.getUrl() != targetUrl) {
    location.setUrl(targetUrl)
    location.save()
}
EOF
sudo chown jenkins:jenkins /var/lib/jenkins/init.groovy.d/10-https-url.groovy

sudo tee /var/lib/jenkins/jenkins.model.JenkinsLocationConfiguration.xml >/dev/null <<EOF
<?xml version='1.1' encoding='UTF-8'?>
<jenkins.model.JenkinsLocationConfiguration>
  <jenkinsUrl>https://${PUBLIC_IP}/</jenkinsUrl>
</jenkins.model.JenkinsLocationConfiguration>
EOF
sudo chown jenkins:jenkins /var/lib/jenkins/jenkins.model.JenkinsLocationConfiguration.xml

echo ""
echo "=== Jenkins localhost-only ==="
sudo sed -i 's/^JENKINS_LISTEN_ADDRESS=.*/JENKINS_LISTEN_ADDRESS=127.0.0.1/' /etc/sysconfig/jenkins
grep JENKINS_LISTEN_ADDRESS /etc/sysconfig/jenkins || echo "JENKINS_LISTEN_ADDRESS=127.0.0.1" | sudo tee -a /etc/sysconfig/jenkins

echo ""
echo "=== Firewall: open 443, close 8080 ==="
sudo firewall-cmd --permanent --add-port=443/tcp 2>/dev/null || true
sudo firewall-cmd --permanent --remove-port=8080/tcp 2>/dev/null || true
sudo firewall-cmd --reload
sudo firewall-cmd --list-ports

echo ""
echo "=== Restart nginx + Jenkins ==="
sudo nginx -t
sudo systemctl reload nginx
sudo systemctl restart jenkins
sleep 10

echo ""
echo "=== Done. Test: curl -kI https://${PUBLIC_IP}/ ==="
curl -k -sI "https://${PUBLIC_IP}/" | head -10
