// BadgerLabs wake listener for ESP32 (~30 RON board): wakes nuclear powerplants from ANY network.
//
// Plug it into a USB charger anywhere in the powerplant's home (same Wi-Fi/LAN as the PC).
// It polls a private ntfy.sh topic over HTTPS every few seconds; when you press "Wake" anywhere
// (terminal, VS Code, dashboard) it gets "wake <MAC>" and sends the Wake-on-LAN magic packet.
// No port forwarding, no Tailscale, no account.
//
// Arduino IDE: Boards Manager -> "esp32 by Espressif", select your board (e.g. "ESP32 Dev Module"),
// fill in the 3 settings below, Upload. Serial Monitor (115200) shows what it does.

#include <WiFi.h>
#include <WiFiUdp.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>

// ---------------- settings ----------------
const char* WIFI_SSID = "your-wifi-name";
const char* WIFI_PASS = "your-wifi-password";
const char* TOPICS    = "badger-wake-xxxxxxxxxxxxxxxxxxxxxxxx";  // shown by list-powerplants; several: "t1,t2"
const char* SERVER    = "https://ntfy.sh";
const unsigned long POLL_MS = 5000;
// ------------------------------------------

WiFiUDP udp;
String since = "30s";          // first poll: anything from the last 30 s, then by message id

bool parseMac(const String& s, uint8_t mac[6]) {
  // finds the first aa:bb:cc:dd:ee:ff / aa-bb-... in s
  for (int i = 0; i + 17 <= (int)s.length(); i++) {
    bool ok = true;
    for (int k = 0; k < 17 && ok; k++) {
      char c = s[i + k];
      if (k % 3 == 2) ok = (c == ':' || c == '-');
      else ok = isxdigit(c);
    }
    if (ok) {
      for (int b = 0; b < 6; b++) mac[b] = strtoul(s.substring(i + b * 3, i + b * 3 + 2).c_str(), nullptr, 16);
      return true;
    }
  }
  return false;
}

void sendWol(const uint8_t mac[6]) {
  uint8_t packet[102];
  memset(packet, 0xFF, 6);
  for (int r = 0; r < 16; r++) memcpy(packet + 6 + r * 6, mac, 6);
  IPAddress bcast = WiFi.localIP() | ~WiFi.subnetMask();
  IPAddress targets[2] = { IPAddress(255, 255, 255, 255), bcast };
  for (auto& t : targets) for (int port : {7, 9}) { udp.beginPacket(t, port); udp.write(packet, sizeof(packet)); udp.endPacket(); }
  Serial.printf("magic packet sent for %02X:%02X:%02X:%02X:%02X:%02X\n", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
  digitalWrite(LED_BUILTIN, HIGH); delay(300); digitalWrite(LED_BUILTIN, LOW);
}

void connectWifi() {
  if (WiFi.status() == WL_CONNECTED) return;
  Serial.printf("Wi-Fi: connecting to %s", WIFI_SSID);
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  for (int i = 0; i < 40 && WiFi.status() != WL_CONNECTED; i++) { delay(500); Serial.print('.'); }
  Serial.println(WiFi.status() == WL_CONNECTED ? " connected, IP " + WiFi.localIP().toString() : " failed");
}

void setup() {
  Serial.begin(115200);
  pinMode(LED_BUILTIN, OUTPUT);
  connectWifi();
  udp.begin(0);
}

void loop() {
  connectWifi();
  if (WiFi.status() == WL_CONNECTED) {
    WiFiClientSecure tls;
    tls.setInsecure();                     // ntfy topic is the secret; no certificate pinning on this tiny board
    HTTPClient http;
    String url = String(SERVER) + "/" + TOPICS + "/json?poll=1&since=" + since;
    if (http.begin(tls, url)) {
      int code = http.GET();
      if (code == 200) {
        String body = http.getString();    // one JSON object per line
        int start = 0;
        while (start < (int)body.length()) {
          int end = body.indexOf('\n', start); if (end < 0) end = body.length();
          String line = body.substring(start, end);
          start = end + 1;
          int idPos = line.indexOf("\"id\":\"");
          if (idPos >= 0) since = line.substring(idPos + 6, line.indexOf('"', idPos + 6));
          int msgPos = line.indexOf("\"message\":\"");
          if (line.indexOf("\"event\":\"message\"") < 0 || msgPos < 0) continue;
          String msg = line.substring(msgPos + 11, line.indexOf('"', msgPos + 11));
          uint8_t mac[6];
          if (msg.startsWith("wake") && parseMac(msg, mac)) sendWol(mac);
        }
      } else {
        Serial.printf("ntfy poll failed: HTTP %d\n", code);
      }
      http.end();
    }
  }
  delay(POLL_MS);
}
