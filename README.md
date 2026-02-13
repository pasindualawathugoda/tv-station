# 📺 24/7 TV Station - One Click Installer

## Install (One Command)


##Requirements 

Ubuntu 20.04 / 22.04 / 24.04
Minimum 2 CPU, 2GB RAM
Root access
After Install
Dashboard: http://YOUR_IP
Login: admin / 123456
Change password immediately!


33Features
✅ 24/7 live TV station
✅ Add video URLs (no upload)
✅ Logo watermark with drag & drop
✅ Schedule playlists
✅ OBS integration
✅ Auto-detect new videos
✅ All formats supported (MP4, MKV, M3U8, etc)

Modification Path:


sudo nano /var/www/tv/scripts/autodj.php

sudo nano /var/www/tv/public/settings.php

sudo nano /var/www/tv/public/dashboard.php

sudo nano /var/www/tv/scripts/autodj.php




Restart Stream:
-------------------------------------
sudo chmod +x /var/www/tv/scripts/autodj.php
sudo chown www-data:www-data /var/www/tv/scripts/autodj.php
-------------------------------------

sudo pkill -f autodj 2>/dev/null
sudo pkill -f "ffmpeg.*stream" 2>/dev/null
rm -f /tmp/autodj.lock /tmp/autodj_state.json
rm -f /var/www/tv/hls/*.ts /var/www/tv/hls/*.m3u8

--------------------------------------

sudo bash /var/www/tv/scripts/start_stream.sh

---------------------------------------------------



Login to your Ubuntu VPS and run:

```bash
curl -sL https://raw.githubusercontent.com/pasindualawathugoda/tv-station/main/install.sh | sudo bash





