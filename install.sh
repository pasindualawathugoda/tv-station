#!/bin/bash

#=============================================
# 24/7 TV STATION - ONE CLICK INSTALLER
#=============================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

clear
echo -e "${PURPLE}"
echo "╔══════════════════════════════════════════════╗"
echo "║                                              ║"
echo "║    📺  24/7 TV STATION INSTALLER  📺        ║"
echo "║                                              ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ Run as root: sudo bash install.sh${NC}"
    exit 1
fi

SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
echo -e "${CYAN}Server IP: ${WHITE}$SERVER_IP${NC}"
echo ""

# STEP 1
echo -e "${YELLOW}[1/12] 📦 Updating system...${NC}"
apt update -qq > /dev/null 2>&1
apt upgrade -y -qq > /dev/null 2>&1
echo -e "${GREEN}  ✅ Done${NC}"

# STEP 2
echo -e "${YELLOW}[2/12] 📦 Installing packages...${NC}"
apt install -y -qq nginx sqlite3 ffmpeg curl unzip > /dev/null 2>&1
PHP_VER=""
for ver in 8.3 8.2 8.1 8.0; do
    if apt-cache show php${ver}-fpm > /dev/null 2>&1; then
        PHP_VER=$ver
        break
    fi
done
if [ -z "$PHP_VER" ]; then
    apt install -y -qq php-fpm php-cli php-mbstring php-xml php-curl php-sqlite3 > /dev/null 2>&1
    PHP_VER=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
else
    apt install -y -qq php${PHP_VER}-fpm php${PHP_VER}-cli php${PHP_VER}-mbstring php${PHP_VER}-xml php${PHP_VER}-curl php${PHP_VER}-sqlite3 > /dev/null 2>&1
fi
echo -e "${GREEN}  ✅ PHP $PHP_VER installed${NC}"

# STEP 3
echo -e "${YELLOW}[3/12] 📁 Creating directories...${NC}"
mkdir -p /var/www/tv/{public/assets/logos,hls,data,scripts}
echo -e "${GREEN}  ✅ Done${NC}"

# STEP 4
echo -e "${YELLOW}[4/12] ⚙️ Configuring Nginx...${NC}"
SOCKET=$(find /var/run/php/ -name "*.sock" 2>/dev/null | head -1)
if [ -z "$SOCKET" ]; then
    systemctl start php${PHP_VER}-fpm 2>/dev/null
    sleep 2
    SOCKET=$(find /var/run/php/ -name "*.sock" 2>/dev/null | head -1)
fi

cat > /etc/nginx/sites-available/tv << NGINXEOF
server {
    listen 80;
    server_name _;
    root /var/www/tv/public;
    index index.php index.html;
    client_max_body_size 100M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${SOCKET};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location /hls {
        alias /var/www/tv/hls;
        types {
            application/vnd.apple.mpegurl m3u8;
            video/mp2t ts;
        }
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header Expires "0";
        add_header Access-Control-Allow-Origin "*";
        sendfile off;
        tcp_nopush off;
        tcp_nodelay on;
        gzip off;
    }

    location /assets {
        alias /var/www/tv/public/assets;
        expires 7d;
    }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/tv /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
echo -e "${GREEN}  ✅ Done${NC}"

# STEP 5
echo -e "${YELLOW}[5/12] 🔧 Configuring PHP...${NC}"
PHP_INI="/etc/php/${PHP_VER}/fpm/php.ini"
if [ -f "$PHP_INI" ]; then
    sed -i 's/shell_exec,//g; s/,shell_exec//g' "$PHP_INI"
    sed -i 's/proc_open,//g; s/,proc_open//g' "$PHP_INI"
    sed -i 's/popen,//g; s/,popen//g' "$PHP_INI"
    sed -i 's/pcntl_signal,//g; s/,pcntl_signal//g' "$PHP_INI"
    sed -i 's/pcntl_signal_dispatch,//g; s/,pcntl_signal_dispatch//g' "$PHP_INI"
    sed -i 's/proc_get_status,//g; s/,proc_get_status//g' "$PHP_INI"
    sed -i 's/proc_terminate,//g; s/,proc_terminate//g' "$PHP_INI"
    sed -i 's/proc_close,//g; s/,proc_close//g' "$PHP_INI"
fi
echo -e "${GREEN}  ✅ Done${NC}"

# STEP 6
echo -e "${YELLOW}[6/12] 🔐 Setting permissions...${NC}"
echo 'www-data ALL=(ALL) NOPASSWD: /usr/bin/pkill, /bin/bash /var/www/tv/scripts/start_stream.sh, /usr/bin/ffmpeg, /bin/kill, /usr/bin/killall' > /etc/sudoers.d/tv-autodj
chmod 440 /etc/sudoers.d/tv-autodj
echo -e "${GREEN}  ✅ Done${NC}"

# STEP 7
echo -e "${YELLOW}[7/12] 🗄️ Creating database...${NC}"
sqlite3 /var/www/tv/data/tv.db << 'DBEOF'
CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT,username TEXT UNIQUE NOT NULL,password TEXT NOT NULL,created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS settings (id INTEGER PRIMARY KEY AUTOINCREMENT,setting_key TEXT UNIQUE NOT NULL,setting_value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS playlists (id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,created_at DATETIME DEFAULT CURRENT_TIMESTAMP,is_active INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS videos (id INTEGER PRIMARY KEY AUTOINCREMENT,playlist_id INTEGER NOT NULL,title TEXT NOT NULL,url TEXT NOT NULL,duration INTEGER DEFAULT 0,sort_order INTEGER DEFAULT 0,FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE);
CREATE TABLE IF NOT EXISTS schedule (id INTEGER PRIMARY KEY AUTOINCREMENT,playlist_id INTEGER NOT NULL,day_of_week INTEGER DEFAULT -1,start_time TEXT NOT NULL,end_time TEXT NOT NULL,is_recurring INTEGER DEFAULT 1,specific_date TEXT DEFAULT NULL,created_at DATETIME DEFAULT CURRENT_TIMESTAMP,FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE);
CREATE TABLE IF NOT EXISTS obs_config (id INTEGER PRIMARY KEY AUTOINCREMENT,is_obs_live INTEGER DEFAULT 0,obs_stream_key TEXT DEFAULT '',updated_at DATETIME DEFAULT CURRENT_TIMESTAMP);
INSERT OR IGNORE INTO settings (setting_key,setting_value) VALUES ('channel_name','My TV Station');
INSERT OR IGNORE INTO settings (setting_key,setting_value) VALUES ('channel_logo','');
INSERT OR IGNORE INTO settings (setting_key,setting_value) VALUES ('logo_position','top-right');
INSERT OR IGNORE INTO settings (setting_key,setting_value) VALUES ('logo_size','80');
INSERT OR IGNORE INTO settings (setting_key,setting_value) VALUES ('logo_opacity','70');
INSERT OR IGNORE INTO settings (setting_key,setting_value) VALUES ('logo_padding','20');
INSERT OR IGNORE INTO settings (setting_key,setting_value) VALUES ('logo_radius','0');
INSERT OR IGNORE INTO settings (setting_key,setting_value) VALUES ('logo_x','-1');
INSERT OR IGNORE INTO settings (setting_key,setting_value) VALUES ('logo_y','-1');
INSERT OR IGNORE INTO obs_config (is_obs_live,obs_stream_key) VALUES (0,'mystream');
.quit
DBEOF
HASH=$(php -r "echo password_hash('123456', PASSWORD_DEFAULT);")
sqlite3 /var/www/tv/data/tv.db "INSERT OR IGNORE INTO users (username,password) VALUES ('admin','$HASH');"
echo -e "${GREEN}  ✅ Done (admin/123456)${NC}"

# STEP 8
echo -e "${YELLOW}[8/12] 📝 Creating application...${NC}"

# config.php
cat > /var/www/tv/public/config.php << 'PHPEOF'
<?php
session_start();
define('DB_PATH','/var/www/tv/data/tv.db');define('HLS_PATH','/var/www/tv/hls');define('LOGO_PATH','/var/www/tv/public/assets/logos/');define('LOGO_URL','/assets/logos/');
function getDB(){try{$db=new SQLite3(DB_PATH);$db->busyTimeout(5000);$db->exec('PRAGMA journal_mode=WAL');$db->exec('PRAGMA foreign_keys=ON');return $db;}catch(Exception $e){die("DB Error");}}
function isLoggedIn(){return isset($_SESSION['logged_in'])&&$_SESSION['logged_in']===true;}
function requireLogin(){if(!isLoggedIn()){header('Location: login.php');exit;}}
function getSetting($k){try{$db=getDB();$s=$db->prepare('SELECT setting_value FROM settings WHERE setting_key=:k');$s->bindValue(':k',$k);$r=$s->execute();$row=$r->fetchArray(SQLITE3_ASSOC);$db->close();return $row?$row['setting_value']:'';}catch(Exception $e){return '';}}
function setSetting($k,$v){$db=getDB();$s=$db->prepare('INSERT OR REPLACE INTO settings (setting_key,setting_value) VALUES (:k,:v)');$s->bindValue(':k',$k);$s->bindValue(':v',$v);$s->execute();$db->close();}
function getOBSStatus(){try{$db=getDB();$r=$db->query('SELECT * FROM obs_config WHERE id=1');$row=$r->fetchArray(SQLITE3_ASSOC);$db->close();return $row?:['is_obs_live'=>0,'obs_stream_key'=>'mystream'];}catch(Exception $e){return['is_obs_live'=>0,'obs_stream_key'=>'mystream'];}}
function flashMessage($m,$t='success'){$_SESSION['flash']=['message'=>$m,'type'=>$t];}
function showFlash(){if(isset($_SESSION['flash'])){$f=$_SESSION['flash'];unset($_SESSION['flash']);$bg=$f['type']==='success'?'rgba(34,197,94,.08)':'rgba(239,68,68,.08)';$bc=$f['type']==='success'?'rgba(34,197,94,.15)':'rgba(239,68,68,.15)';$tc=$f['type']==='success'?'#22C55E':'#EF4444';echo"<div style='padding:13px 18px;border-radius:10px;margin-bottom:18px;font-size:13px;font-weight:600;background:{$bg};border:1px solid {$bc};color:{$tc}'>{$f['message']}</div>";}}
?>
PHPEOF

# index.php
cat > /var/www/tv/public/index.php << 'PHPEOF'
<?php require_once 'config.php';header('Location: '.(isLoggedIn()?'dashboard.php':'login.php'));exit;?>
PHPEOF

# login.php
cat > /var/www/tv/public/login.php << 'PHPEOF'
<?php
require_once 'config.php';if(isLoggedIn()){header('Location: dashboard.php');exit;}$error='';
if($_SERVER['REQUEST_METHOD']==='POST'){$u=trim($_POST['username']??'');$p=$_POST['password']??'';$db=getDB();$s=$db->prepare('SELECT * FROM users WHERE username=:u');$s->bindValue(':u',$u);$r=$s->execute();$user=$r->fetchArray(SQLITE3_ASSOC);$db->close();
if($user&&password_verify($p,$user['password'])){$_SESSION['logged_in']=true;$_SESSION['user_id']=$user['id'];$_SESSION['username']=$user['username'];header('Location: dashboard.php');exit;}else{$error='Invalid credentials!';}}
$cn=getSetting('channel_name')?:'My TV Station';
?><!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Login</title><link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap" rel="stylesheet"><style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:'Inter',sans-serif;background:linear-gradient(135deg,#06070A,#0D0F14,#06070A);min-height:100vh;display:flex;align-items:center;justify-content:center}.box{background:rgba(255,255,255,.03);backdrop-filter:blur(20px);border:1px solid rgba(255,255,255,.06);border-radius:24px;padding:48px 40px;width:420px;max-width:92%}.hdr{text-align:center;margin-bottom:36px}.icon{width:72px;height:72px;background:linear-gradient(135deg,#5B5EF4,#8B5CF6);border-radius:18px;display:flex;align-items:center;justify-content:center;margin:0 auto 18px;font-size:32px}.hdr h1{color:#F1F3F5;font-size:22px;font-weight:800}.hdr p{color:#495057;font-size:13px;margin-top:6px}.fg{margin-bottom:18px}.fg label{display:block;color:#868E96;margin-bottom:7px;font-size:13px;font-weight:600}.fg input{width:100%;padding:13px 16px;background:rgba(255,255,255,.05);border:1px solid rgba(255,255,255,.1);border-radius:12px;color:#F1F3F5;font-size:14px;outline:none;font-family:'Inter',sans-serif}.fg input:focus{border-color:#5B5EF4}.btn{width:100%;padding:14px;background:linear-gradient(135deg,#5B5EF4,#764ba2);border:none;border-radius:12px;color:#fff;font-size:15px;font-weight:700;cursor:pointer;margin-top:8px;font-family:'Inter',sans-serif}.btn:hover{transform:translateY(-2px);box-shadow:0 8px 25px rgba(91,94,244,.35)}.err{background:rgba(239,68,68,.1);border:1px solid rgba(239,68,68,.2);color:#EF4444;padding:12px;border-radius:10px;margin-bottom:18px;font-size:13px;text-align:center;font-weight:600}</style></head><body><div class="box"><div class="hdr"><div class="icon">📺</div><h1><?php echo htmlspecialchars($cn);?></h1><p>TV Station Control Panel</p></div><?php if($error):?><div class="err"><?php echo $error;?></div><?php endif;?><form method="POST"><div class="fg"><label>Username</label><input type="text" name="username" required autofocus></div><div class="fg"><label>Password</label><input type="password" name="password" required></div><button type="submit" class="btn">🔐 Sign In</button></form></div></body></html>
PHPEOF

# logout.php
cat > /var/www/tv/public/logout.php << 'PHPEOF'
<?php session_start();session_destroy();header('Location: login.php');exit;?>
PHPEOF

# stream_control.php
cat > /var/www/tv/public/stream_control.php << 'PHPEOF'
<?php
require_once 'config.php';requireLogin();$a=$_GET['action']??'';
switch($a){case 'start':shell_exec('sudo pkill -f "autodj.php" 2>/dev/null');shell_exec('sudo pkill -f "ffmpeg.*stream" 2>/dev/null');sleep(2);shell_exec('rm -f /var/www/tv/hls/*.ts /var/www/tv/hls/*.m3u8 /tmp/autodj.lock /tmp/autodj_state.json 2>/dev/null');shell_exec('sudo bash /var/www/tv/scripts/start_stream.sh > /dev/null 2>&1 &');sleep(3);flashMessage('AutoDJ started!');break;
case 'stop':shell_exec('sudo pkill -f "autodj.php" 2>/dev/null');shell_exec('sudo pkill -f "ffmpeg.*stream" 2>/dev/null');sleep(1);shell_exec('rm -f /var/www/tv/hls/*.ts /var/www/tv/hls/*.m3u8 /tmp/autodj.lock 2>/dev/null');flashMessage('Stopped!');break;
case 'obs_on':$db=getDB();$db->exec('UPDATE obs_config SET is_obs_live=1 WHERE id=1');$db->close();shell_exec('sudo pkill -f "autodj.php" 2>/dev/null');shell_exec('sudo pkill -f "ffmpeg.*stream" 2>/dev/null');shell_exec('rm -f /tmp/autodj.lock 2>/dev/null');flashMessage('OBS ON!');break;
case 'obs_off':$db=getDB();$db->exec('UPDATE obs_config SET is_obs_live=0 WHERE id=1');$db->close();sleep(1);shell_exec('rm -f /tmp/autodj.lock 2>/dev/null');shell_exec('sudo bash /var/www/tv/scripts/start_stream.sh > /dev/null 2>&1 &');flashMessage('AutoDJ restarting!');break;}
header('Location: dashboard.php');exit;?>
PHPEOF

# api_status.php
cat > /var/www/tv/public/api_status.php << 'PHPEOF'
<?php require_once 'config.php';header('Content-Type:application/json');header('Access-Control-Allow-Origin:*');$obs=getOBSStatus();echo json_encode(['stream'=>!empty(shell_exec('pgrep -f "ffmpeg.*stream" 2>/dev/null')),'obs'=>(bool)$obs['is_obs_live'],'channel'=>getSetting('channel_name')]);?>
PHPEOF

echo -e "${GREEN}  ✅ Core files created${NC}"

# dashboard.php - Download from separate file or embed
echo -e "${YELLOW}  Creating dashboard...${NC}"

cat > /var/www/tv/public/dashboard.php << 'DASHEOF'
<?php
ini_set('display_errors',1);error_reporting(E_ALL);session_start();
if(!isset($_SESSION['logged_in'])||$_SESSION['logged_in']!==true){header('Location: login.php');exit;}
$db=new SQLite3('/var/www/tv/data/tv.db');$db->busyTimeout(5000);
$tp=(int)$db->querySingle('SELECT COUNT(*) FROM playlists');$tv=(int)$db->querySingle('SELECT COUNT(*) FROM videos');$ts=(int)$db->querySingle('SELECT COUNT(*) FROM schedule');
$ap=$db->querySingle("SELECT name FROM playlists WHERE is_active=1")?:'None';$ol=(int)$db->querySingle('SELECT is_obs_live FROM obs_config WHERE id=1');
$rv=[];$r=$db->query('SELECT v.title,p.name as pname FROM videos v LEFT JOIN playlists p ON v.playlist_id=p.id ORDER BY v.id DESC LIMIT 5');if($r)while($row=$r->fetchArray(SQLITE3_ASSOC))$rv[]=$row;
$cn=$db->querySingle("SELECT setting_value FROM settings WHERE setting_key='channel_name'")?:'My TV Station';
$cl=$db->querySingle("SELECT setting_value FROM settings WHERE setting_key='channel_logo'")?:'';$db->close();
$sr=!empty(trim(shell_exec('pgrep -f "autodj.php" 2>/dev/null')));$fr=!empty(trim(shell_exec('pgrep -f "ffmpeg.*stream" 2>/dev/null')));$il=$sr||$fr||$ol;
$np='Nothing';if(file_exists('/var/log/autodj.log')){$ls=@file('/var/log/autodj.log',FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES);if($ls)for($i=count($ls)-1;$i>=max(0,count($ls)-50);$i--)if(strpos($ls[$i],'PLAYING:')!==false){$np=trim(substr($ls[$i],strpos($ls[$i],'PLAYING:')+8));break;}}
$fm='';if(isset($_SESSION['flash'])){$f=$_SESSION['flash'];unset($_SESSION['flash']);$fc=$f['type']==='success'?'#22C55E':'#EF4444';$fm="<div style='padding:12px 18px;border-radius:10px;margin-bottom:18px;font-size:13px;font-weight:600;background:rgba(0,0,0,.3);border:1px solid {$fc}33;color:{$fc}'>{$f['message']}</div>";}
$hl=$cl&&file_exists('/var/www/tv/public/assets/logos/'.$cl);$lh=$hl?'<img src="/assets/logos/'.htmlspecialchars($cl).'" style="width:40px;height:40px;border-radius:10px;object-fit:cover">':'<div style="width:40px;height:40px;border-radius:10px;background:linear-gradient(135deg,#5B5EF4,#8B5CF6);display:flex;align-items:center;justify-content:center;font-size:18px">📺</div>';
?><!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Dashboard</title><link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap" rel="stylesheet">
<style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:'Inter',sans-serif;background:#06070A;color:#F1F3F5;min-height:100vh}a{color:inherit;text-decoration:none}.sidebar{position:fixed;left:0;top:0;bottom:0;width:260px;background:#0D0F14;border-right:1px solid rgba(255,255,255,.05);z-index:100;display:flex;flex-direction:column}.sb-h{padding:20px;border-bottom:1px solid rgba(255,255,255,.05);display:flex;align-items:center;gap:12px}.sb-h h2{font-size:14px;font-weight:700}.sb-h small{display:block;font-size:10px;color:#495057;text-transform:uppercase;letter-spacing:1px}.sb-nav{flex:1;padding:14px 0}.nl{padding:6px 20px;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:1.5px;color:#495057;margin-top:10px}.na{display:flex;align-items:center;gap:12px;padding:10px 20px;font-size:13px;font-weight:500;color:#868E96;border-left:3px solid transparent;transition:all .15s}.na:hover{color:#F1F3F5;background:rgba(255,255,255,.02)}.na.on{color:#5B5EF4;background:rgba(91,94,244,.07);border-left-color:#5B5EF4}.na span{font-size:16px;width:20px;text-align:center}.sb-f{padding:14px 20px;border-top:1px solid rgba(255,255,255,.05);display:flex;align-items:center;gap:10px;font-size:12px}.sb-av{width:30px;height:30px;border-radius:8px;background:linear-gradient(135deg,#5B5EF4,#8B5CF6);display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:700}.main{margin-left:260px}.top{position:sticky;top:0;z-index:50;padding:14px 24px;display:flex;align-items:center;justify-content:space-between;background:rgba(6,7,10,.85);backdrop-filter:blur(16px);border-bottom:1px solid rgba(255,255,255,.05)}.top h1{font-size:20px;font-weight:800}.top small{font-size:11px;color:#495057;display:block;margin-top:2px}.pill{display:inline-flex;align-items:center;gap:6px;padding:5px 14px;border-radius:100px;font-size:10px;font-weight:800;letter-spacing:.8px}.pill.on{background:rgba(239,68,68,.1);color:#EF4444;border:1px solid rgba(239,68,68,.15);animation:pp 2s infinite}.pill.off{background:rgba(255,255,255,.03);color:#495057;border:1px solid rgba(255,255,255,.06)}@keyframes pp{0%,100%{box-shadow:0 0 0 0 rgba(239,68,68,.25)}50%{box-shadow:0 0 0 6px transparent}}.dot{width:6px;height:6px;border-radius:50%;background:currentColor}.ct{padding:22px 24px}.np{background:linear-gradient(135deg,rgba(91,94,244,.06),rgba(139,92,246,.04));border:1px solid rgba(91,94,244,.1);border-radius:12px;padding:14px 18px;margin-bottom:22px;display:flex;align-items:center;gap:12px}.np-i{width:38px;height:38px;background:#5B5EF4;border-radius:10px;display:flex;align-items:center;justify-content:center;font-size:17px}.np-l{font-size:9px;text-transform:uppercase;letter-spacing:1.5px;color:#5B5EF4;font-weight:700}.np-t{font-size:13px;font-weight:600;margin-top:2px}.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin-bottom:22px}.st{background:#12141A;border:1px solid rgba(255,255,255,.05);border-radius:12px;padding:18px;position:relative;overflow:hidden;transition:all .2s}.st:hover{border-color:rgba(255,255,255,.08);transform:translateY(-2px)}.st::before{content:'';position:absolute;top:0;left:0;right:0;height:2px}.st:nth-child(1)::before{background:#5B5EF4}.st:nth-child(2)::before{background:#22C55E}.st:nth-child(3)::before{background:#F59E0B}.st:nth-child(4)::before{background:#EF4444}.sti{width:36px;height:36px;border-radius:10px;display:flex;align-items:center;justify-content:center;font-size:16px;margin-bottom:12px}.stv{font-size:28px;font-weight:800;letter-spacing:-1px}.stl{font-size:10px;color:#495057;font-weight:600;text-transform:uppercase;letter-spacing:.5px;margin-top:4px}.g2{display:grid;grid-template-columns:1.4fr 1fr;gap:16px}.card{background:#12141A;border:1px solid rgba(255,255,255,.05);border-radius:12px;overflow:hidden;margin-bottom:16px}.ch{display:flex;align-items:center;justify-content:space-between;padding:14px 18px;border-bottom:1px solid rgba(255,255,255,.05)}.ch h3{font-size:12px;font-weight:700}.cb{padding:16px 18px}.btn{display:inline-flex;align-items:center;gap:6px;padding:6px 12px;background:#5B5EF4;color:#fff;border:none;border-radius:8px;font-size:10px;font-weight:600;cursor:pointer}.btn:hover{background:#4A4DD4}.pv{background:#000;border-radius:8px;overflow:hidden;aspect-ratio:16/9;position:relative;display:flex;align-items:center;justify-content:center}.pv video{width:100%;height:100%;object-fit:contain}.pv-off{color:#495057;text-align:center;font-size:12px}.pv-off .icon{font-size:36px;opacity:.2;margin-bottom:8px}.pv-badge{position:absolute;top:8px;left:8px;background:#EF4444;padding:2px 8px;border-radius:4px;font-size:9px;font-weight:800}.cg{display:grid;grid-template-columns:1fr 1fr;gap:8px}.ct-btn{display:flex;flex-direction:column;align-items:center;gap:6px;padding:14px 8px;background:rgba(255,255,255,.015);border:1px solid rgba(255,255,255,.05);border-radius:10px;color:#868E96;font-size:10px;font-weight:600;transition:all .15s;cursor:pointer}.ct-btn:hover{background:rgba(91,94,244,.06);border-color:rgba(91,94,244,.15);color:#F1F3F5;transform:translateY(-1px)}.ct-btn .ci{font-size:20px}.ir{display:flex;justify-content:space-between;align-items:center;padding:8px 0;border-bottom:1px solid rgba(255,255,255,.04);font-size:11px}.ir:last-child{border-bottom:none}.ir .l{color:#495057}.ir .v{font-weight:600;font-family:monospace;font-size:10px}.li{display:flex;align-items:center;gap:10px;padding:10px 0;border-bottom:1px solid rgba(255,255,255,.04)}.li:last-child{border-bottom:none}.li-i{width:30px;height:30px;border-radius:8px;background:rgba(255,255,255,.03);display:flex;align-items:center;justify-content:center;font-size:13px;flex-shrink:0}.li-t{font-size:11px;font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.li-s{font-size:9px;color:#495057;margin-top:1px}@media(max-width:1100px){.stats{grid-template-columns:1fr 1fr}.g2{grid-template-columns:1fr}}@media(max-width:768px){.sidebar{display:none}.main{margin-left:0}}</style></head>
<body><aside class="sidebar"><div class="sb-h"><?php echo $lh;?><div><h2><?php echo htmlspecialchars($cn);?></h2><small>Control Panel</small></div></div><nav class="sb-nav"><div class="nl">Main</div><a href="dashboard.php" class="na on"><span>📊</span> Dashboard</a><a href="playlist.php" class="na"><span>📋</span> Playlists</a><a href="schedule.php" class="na"><span>📅</span> Schedule</a><div class="nl">System</div><a href="settings.php" class="na"><span>⚙️</span> Settings</a><a href="player.php" target="_blank" class="na"><span>🖥️</span> Watch Live</a><a href="logout.php" class="na"><span>🚪</span> Sign Out</a></nav><div class="sb-f"><div class="sb-av"><?php echo strtoupper(substr($_SESSION['username']??'A',0,1));?></div><div><div style="font-weight:600"><?php echo htmlspecialchars($_SESSION['username']??'admin');?></div><div style="font-size:10px;color:#495057">Admin</div></div></div></aside>
<div class="main"><div class="top"><div><h1>Dashboard</h1><small><?php echo date('l, F j, Y');?></small></div><div><?php if($il):?><div class="pill on"><span class="dot"></span>ON AIR</div><?php else:?><div class="pill off"><span class="dot"></span>OFFLINE</div><?php endif;?></div></div>
<div class="ct"><?php echo $fm;?><?php if($il):?><div class="np"><div class="np-i">🎵</div><div style="flex:1"><div class="np-l">Now Playing</div><div class="np-t"><?php echo htmlspecialchars($np);?></div></div><a href="player.php" target="_blank" class="btn">▶ Watch</a></div><?php endif;?>
<div class="stats"><div class="st"><div class="sti" style="background:rgba(91,94,244,.08);color:#5B5EF4">📋</div><div class="stv"><?php echo $tp;?></div><div class="stl">Playlists</div></div><div class="st"><div class="sti" style="background:rgba(34,197,94,.08);color:#22C55E">🎬</div><div class="stv"><?php echo $tv;?></div><div class="stl">Videos</div></div><div class="st"><div class="sti" style="background:rgba(245,158,11,.08);color:#F59E0B">📅</div><div class="stv"><?php echo $ts;?></div><div class="stl">Schedules</div></div><div class="st"><div class="sti" style="background:rgba(239,68,68,.08);color:#EF4444">📡</div><div class="stv" style="font-size:18px;color:<?php echo $il?'#22C55E':'#495057';?>"><?php echo $il?'● LIVE':'○ OFF';?></div><div class="stl">Stream</div></div></div>
<div class="g2"><div><div class="card"><div class="ch"><h3>🖥️ Preview</h3><a href="player.php" target="_blank" class="btn">Open ↗</a></div><div class="cb"><div class="pv"><?php if($il):?><span class="pv-badge">● LIVE</span><video id="pv" autoplay muted playsinline></video><?php else:?><div class="pv-off"><div class="icon">📺</div><p>Start AutoDJ to go live</p></div><?php endif;?></div></div></div><div class="card"><div class="ch"><h3>🎬 Recent</h3><a href="playlist.php" class="btn">All</a></div><div class="cb"><?php if(empty($rv)):?><div style="text-align:center;padding:20px;color:#495057;font-size:12px">No videos</div><?php else:foreach($rv as $v):?><div class="li"><div class="li-i">🎬</div><div style="flex:1;min-width:0"><div class="li-t"><?php echo htmlspecialchars($v['title']);?></div><div class="li-s"><?php echo htmlspecialchars($v['pname']??'');?></div></div></div><?php endforeach;endif;?></div></div></div>
<div><div class="card"><div class="ch"><h3>🎛️ Controls</h3></div><div class="cb"><div class="cg"><a href="stream_control.php?action=start" class="ct-btn" onclick="return confirm('Start?')"><span class="ci">▶️</span>Start AutoDJ</a><a href="stream_control.php?action=stop" class="ct-btn" onclick="return confirm('Stop?')"><span class="ci">⏹️</span>Stop</a><a href="stream_control.php?action=obs_on" class="ct-btn" onclick="return confirm('OBS?')"><span class="ci">🎥</span>OBS Mode</a><a href="stream_control.php?action=obs_off" class="ct-btn" onclick="return confirm('Auto?')"><span class="ci">🤖</span>Auto Mode</a></div></div></div>
<div class="card"><div class="ch"><h3>📡 Info</h3></div><div class="cb"><div class="ir"><span class="l">Playlist</span><span class="v"><?php echo htmlspecialchars($ap);?></span></div><div class="ir"><span class="l">AutoDJ</span><span class="v" style="color:<?php echo $sr?'#22C55E':'#495057';?>"><?php echo $sr?'● Run':'○ Stop';?></span></div><div class="ir"><span class="l">FFmpeg</span><span class="v" style="color:<?php echo $fr?'#22C55E':'#495057';?>"><?php echo $fr?'● On':'○ Off';?></span></div><div class="ir"><span class="l">OBS</span><span class="v" style="color:<?php echo $ol?'#F59E0B':'#495057';?>"><?php echo $ol?'● On':'○ Off';?></span></div><div class="ir"><span class="l">HLS</span><span class="v" style="font-size:9px">/hls/stream.m3u8</span></div></div></div></div></div></div></div>
<?php if($il):?><script src="https://cdn.jsdelivr.net/npm/hls.js@1.4.14/dist/hls.min.js"></script><script>var v=document.getElementById('pv');if(v&&typeof Hls!=='undefined'&&Hls.isSupported()){var h=new Hls({liveSyncDurationCount:2,maxBufferLength:10});h.loadSource('/hls/stream.m3u8');h.attachMedia(v);h.on(Hls.Events.MANIFEST_PARSED,function(){v.play().catch(function(){})});h.on(Hls.Events.ERROR,function(e,d){if(d.fatal)setTimeout(function(){h.loadSource('/hls/stream.m3u8')},3000)})}</script><?php endif;?><script>setTimeout(function(){location.reload()},30000)</script></body></html>
DASHEOF

echo -e "${GREEN}  ✅ Dashboard created${NC}"

# Create remaining pages using the previous full tutorial content
# playlist.php, schedule.php, settings.php, player.php
# (These are downloaded from the repo or embedded)

echo -e "${YELLOW}  Creating playlist, schedule, settings, player...${NC}"

# I'll create a download helper for the remaining large files
# For now, create minimal working versions

# PLAYLIST PAGE
curl -sL "https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/tv-station/main/public/playlist.php" -o /var/www/tv/public/playlist.php 2>/dev/null

# If curl fails, create inline
if [ ! -s /var/www/tv/public/playlist.php ]; then
cat > /var/www/tv/public/playlist.php << 'PLEOF'
<?php
require_once 'config.php';requireLogin();$db=getDB();
if($_SERVER['REQUEST_METHOD']==='POST'){$a=$_POST['action']??'';
if($a==='create_playlist'){$n=trim($_POST['name']??'');if($n){$s=$db->prepare('INSERT INTO playlists (name) VALUES (:n)');$s->bindValue(':n',$n);$s->execute();flashMessage("Created!");}}
if($a==='delete_playlist'){$db->exec("DELETE FROM playlists WHERE id=".(int)$_POST['playlist_id']);flashMessage('Deleted!');}
if($a==='set_active'){$db->exec('UPDATE playlists SET is_active=0');$db->exec("UPDATE playlists SET is_active=1 WHERE id=".(int)$_POST['playlist_id']);flashMessage('Active!');}
if($a==='add_video'){$pid=(int)$_POST['playlist_id'];$t=trim($_POST['title']??'');$u=trim($_POST['url']??'');if($t&&$u){$mx=$db->querySingle("SELECT COALESCE(MAX(sort_order),0) FROM videos WHERE playlist_id=$pid");$s=$db->prepare('INSERT INTO videos (playlist_id,title,url,sort_order) VALUES (:p,:t,:u,:o)');$s->bindValue(':p',$pid);$s->bindValue(':t',$t);$s->bindValue(':u',$u);$s->bindValue(':o',$mx+1);$s->execute();flashMessage("Added!");}}
if($a==='delete_video'){$db->exec("DELETE FROM videos WHERE id=".(int)$_POST['video_id']);flashMessage('Deleted!');}
if($a==='move_video'){$id=(int)$_POST['video_id'];$dir=$_POST['direction'];$v=$db->querySingle("SELECT * FROM videos WHERE id=$id",true);if($v){$pid=$v['playlist_id'];$cur=$v['sort_order'];$swap=$dir==='up'?$db->querySingle("SELECT * FROM videos WHERE playlist_id=$pid AND sort_order<$cur ORDER BY sort_order DESC LIMIT 1",true):$db->querySingle("SELECT * FROM videos WHERE playlist_id=$pid AND sort_order>$cur ORDER BY sort_order ASC LIMIT 1",true);if($swap){$db->exec("UPDATE videos SET sort_order={$swap['sort_order']} WHERE id=$id");$db->exec("UPDATE videos SET sort_order=$cur WHERE id={$swap['id']}");}}}
$db->close();header('Location: playlist.php'.(isset($_POST['playlist_id'])?'?view='.(int)$_POST['playlist_id']:''));exit;}
$pls=[];$r=$db->query('SELECT * FROM playlists ORDER BY created_at DESC');while($row=$r->fetchArray(SQLITE3_ASSOC)){$row['vc']=$db->querySingle("SELECT COUNT(*) FROM videos WHERE playlist_id={$row['id']}");$pls[]=$row;}
$vp=null;$vids=[];if(isset($_GET['view'])){$vid=(int)$_GET['view'];$vp=$db->querySingle("SELECT * FROM playlists WHERE id=$vid",true);if($vp){$r=$db->query("SELECT * FROM videos WHERE playlist_id=$vid ORDER BY sort_order ASC");while($row=$r->fetchArray(SQLITE3_ASSOC))$vids[]=$row;}}$db->close();
$cn=getSetting('channel_name')?:'My TV Station';
?><!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Playlists</title><link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600;700;800&display=swap" rel="stylesheet"><style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:'Inter',sans-serif;background:#06070A;color:#F1F3F5;min-height:100vh;padding:20px}.top{display:flex;justify-content:space-between;align-items:center;margin-bottom:20px}.top h1{font-size:22px;font-weight:800}a{color:#5B5EF4}.btn{padding:8px 16px;background:#5B5EF4;color:#fff;border:none;border-radius:8px;font-size:12px;font-weight:600;cursor:pointer;font-family:'Inter',sans-serif;text-decoration:none;display:inline-block}.btn:hover{background:#4A4DD4}.btn-red{background:#EF4444}.btn-green{background:#22C55E;color:#000}.btn-gray{background:rgba(255,255,255,.08)}.card{background:#12141A;border:1px solid rgba(255,255,255,.05);border-radius:12px;padding:20px;margin-bottom:16px}.fg{margin-bottom:12px}.fg label{display:block;color:#868E96;font-size:12px;margin-bottom:4px;font-weight:600}.fg input{width:100%;padding:10px;background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.08);border-radius:8px;color:#fff;font-size:13px;outline:none}.fg input:focus{border-color:#5B5EF4}table{width:100%;border-collapse:collapse}th,td{padding:10px;text-align:left;border-bottom:1px solid rgba(255,255,255,.04);font-size:12px}th{color:#495057;font-size:10px;text-transform:uppercase}.modal{display:none;position:fixed;inset:0;background:rgba(0,0,0,.7);z-index:100;align-items:center;justify-content:center}.modal.show{display:flex}.modal-box{background:#1a1a2e;border-radius:16px;padding:24px;width:450px;max-width:90%}.modal-box h3{margin-bottom:16px}.acts{display:flex;gap:6px;justify-content:flex-end;margin-top:16px}.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:12px}.pc{background:rgba(255,255,255,.02);border:1px solid rgba(255,255,255,.06);border-radius:12px;padding:16px;position:relative}.pc.active{border-color:#22C55E}.pc h4{font-size:14px;margin-bottom:4px}.pc .meta{font-size:11px;color:#495057;margin-bottom:12px}.ab{position:absolute;top:8px;right:8px;background:#22C55E;color:#000;padding:2px 8px;border-radius:10px;font-size:9px;font-weight:700}.nav{margin-bottom:16px;display:flex;gap:8px;flex-wrap:wrap}.nav a{padding:6px 14px;background:rgba(255,255,255,.04);border-radius:8px;color:#868E96;font-size:12px;font-weight:500;text-decoration:none}.nav a:hover,.nav a.on{background:rgba(91,94,244,.1);color:#5B5EF4}</style></head><body>
<div class="nav"><a href="dashboard.php">📊 Dashboard</a><a href="playlist.php" class="on">📋 Playlists</a><a href="schedule.php">📅 Schedule</a><a href="settings.php">⚙️ Settings</a><a href="player.php" target="_blank">🖥️ Watch</a><a href="logout.php">🚪 Logout</a></div>
<?php showFlash();?>
<div class="top"><h1>📋 Playlists</h1><button class="btn" onclick="document.getElementById('cm').classList.add('show')">➕ New</button></div>
<?php if($vp):?><a href="playlist.php" class="btn btn-gray" style="margin-bottom:16px;display:inline-block">← Back</a>
<div class="card"><div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px"><h3><?php echo htmlspecialchars($vp['name']);?> (<?php echo count($vids);?>)</h3><button class="btn" onclick="document.getElementById('am').classList.add('show')">➕ Add Video</button></div>
<?php if(empty($vids)):?><p style="color:#495057;text-align:center;padding:30px">No videos yet</p>
<?php else:?><table><tr><th>#</th><th>Title</th><th>URL</th><th>Order</th><th>Del</th></tr>
<?php foreach($vids as $i=>$v):?><tr><td><?php echo $i+1;?></td><td style="font-weight:600"><?php echo htmlspecialchars($v['title']);?></td><td style="max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:#495057;font-size:10px"><?php echo htmlspecialchars($v['url']);?></td>
<td><form method="POST" style="display:inline"><input type="hidden" name="action" value="move_video"><input type="hidden" name="video_id" value="<?php echo $v['id'];?>"><input type="hidden" name="playlist_id" value="<?php echo $vp['id'];?>"><input type="hidden" name="direction" value="up"><button class="btn btn-gray" style="padding:4px 8px;font-size:10px">⬆</button></form><form method="POST" style="display:inline"><input type="hidden" name="action" value="move_video"><input type="hidden" name="video_id" value="<?php echo $v['id'];?>"><input type="hidden" name="playlist_id" value="<?php echo $vp['id'];?>"><input type="hidden" name="direction" value="down"><button class="btn btn-gray" style="padding:4px 8px;font-size:10px">⬇</button></form></td>
<td><form method="POST" style="display:inline" onsubmit="return confirm('Delete?')"><input type="hidden" name="action" value="delete_video"><input type="hidden" name="video_id" value="<?php echo $v['id'];?>"><input type="hidden" name="playlist_id" value="<?php echo $vp['id'];?>"><button class="btn btn-red" style="padding:4px 8px;font-size:10px">🗑</button></form></td></tr><?php endforeach;?></table><?php endif;?></div>
<div class="modal" id="am"><div class="modal-box"><h3>➕ Add Video</h3><form method="POST"><input type="hidden" name="action" value="add_video"><input type="hidden" name="playlist_id" value="<?php echo $vp['id'];?>"><div class="fg"><label>Title</label><input type="text" name="title" required></div><div class="fg"><label>URL</label><input type="url" name="url" required></div><div class="acts"><button type="button" class="btn btn-gray" onclick="this.closest('.modal').classList.remove('show')">Cancel</button><button class="btn">Add</button></div></form></div></div>
<?php else:?><?php if(empty($pls)):?><div class="card" style="text-align:center;padding:40px"><p style="font-size:40px;margin-bottom:10px">📋</p><p style="color:#495057;margin-bottom:16px">No playlists yet</p><button class="btn" onclick="document.getElementById('cm').classList.add('show')">➕ Create</button></div>
<?php else:?><div class="grid"><?php foreach($pls as $pl):?><div class="pc <?php echo $pl['is_active']?'active':'';?>"><?php if($pl['is_active']):?><div class="ab">▶ ACTIVE</div><?php endif;?><h4><?php echo htmlspecialchars($pl['name']);?></h4><div class="meta">🎬 <?php echo $pl['vc'];?> videos</div><div style="display:flex;gap:6px;flex-wrap:wrap"><a href="playlist.php?view=<?php echo $pl['id'];?>" class="btn" style="font-size:10px;padding:5px 10px">📂 Open</a><?php if(!$pl['is_active']):?><form method="POST" style="display:inline"><input type="hidden" name="action" value="set_active"><input type="hidden" name="playlist_id" value="<?php echo $pl['id'];?>"><button class="btn btn-green" style="font-size:10px;padding:5px 10px">✅ Active</button></form><?php endif;?><form method="POST" style="display:inline" onsubmit="return confirm('Delete?')"><input type="hidden" name="action" value="delete_playlist"><input type="hidden" name="playlist_id" value="<?php echo $pl['id'];?>"><button class="btn btn-red" style="font-size:10px;padding:5px 10px">🗑</button></form></div></div><?php endforeach;?></div><?php endif;endif;?>
<div class="modal" id="cm"><div class="modal-box"><h3>➕ New Playlist</h3><form method="POST"><input type="hidden" name="action" value="create_playlist"><div class="fg"><label>Name</label><input type="text" name="name" required></div><div class="acts"><button type="button" class="btn btn-gray" onclick="this.closest('.modal').classList.remove('show')">Cancel</button><button class="btn">Create</button></div></form></div></div></body></html>
PLEOF
fi

# SCHEDULE PAGE
cat > /var/www/tv/public/schedule.php << 'SCHEOF'
<?php
require_once 'config.php';requireLogin();$db=getDB();
if($_SERVER['REQUEST_METHOD']==='POST'){$a=$_POST['action']??'';
if($a==='add_schedule'){$s=$db->prepare('INSERT INTO schedule (playlist_id,day_of_week,start_time,end_time,is_recurring,specific_date) VALUES (:p,:d,:s,:e,:i,:sd)');$s->bindValue(':p',(int)$_POST['playlist_id']);$s->bindValue(':d',(int)$_POST['day_of_week']);$s->bindValue(':s',$_POST['start_time']);$s->bindValue(':e',$_POST['end_time']);$s->bindValue(':i',isset($_POST['is_recurring'])?1:0);$s->bindValue(':sd',$_POST['specific_date']??null);$s->execute();flashMessage('Added!');}
if($a==='delete_schedule'){$db->exec("DELETE FROM schedule WHERE id=".(int)$_POST['schedule_id']);flashMessage('Deleted!');}
$db->close();header('Location: schedule.php');exit;}
$pls=[];$r=$db->query('SELECT * FROM playlists ORDER BY name');while($row=$r->fetchArray(SQLITE3_ASSOC))$pls[]=$row;
$scs=[];$r=$db->query('SELECT s.*,p.name as pname FROM schedule s JOIN playlists p ON s.playlist_id=p.id ORDER BY s.day_of_week,s.start_time');while($row=$r->fetchArray(SQLITE3_ASSOC))$scs[]=$row;$db->close();
$days=['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
?><!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Schedule</title><link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600;700;800&display=swap" rel="stylesheet"><style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:'Inter',sans-serif;background:#06070A;color:#F1F3F5;min-height:100vh;padding:20px}a{color:#5B5EF4}.btn{padding:8px 16px;background:#5B5EF4;color:#fff;border:none;border-radius:8px;font-size:12px;font-weight:600;cursor:pointer;font-family:'Inter',sans-serif}.btn:hover{background:#4A4DD4}.btn-red{background:#EF4444}.btn-gray{background:rgba(255,255,255,.08)}.card{background:#12141A;border:1px solid rgba(255,255,255,.05);border-radius:12px;padding:20px;margin-bottom:16px}.fg{margin-bottom:12px}.fg label{display:block;color:#868E96;font-size:12px;margin-bottom:4px;font-weight:600}.fg input,.fg select{width:100%;padding:10px;background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.08);border-radius:8px;color:#fff;font-size:13px;outline:none;font-family:'Inter',sans-serif}.fg select option{background:#12141A}.fg2{display:grid;grid-template-columns:1fr 1fr;gap:12px}.modal{display:none;position:fixed;inset:0;background:rgba(0,0,0,.7);z-index:100;align-items:center;justify-content:center}.modal.show{display:flex}.modal-box{background:#1a1a2e;border-radius:16px;padding:24px;width:480px;max-width:90%}.acts{display:flex;gap:6px;justify-content:flex-end;margin-top:16px}.si{display:flex;align-items:center;gap:12px;padding:12px;background:rgba(255,255,255,.02);border:1px solid rgba(255,255,255,.04);border-radius:10px;margin-bottom:8px}.nav{margin-bottom:16px;display:flex;gap:8px;flex-wrap:wrap}.nav a{padding:6px 14px;background:rgba(255,255,255,.04);border-radius:8px;color:#868E96;font-size:12px;font-weight:500;text-decoration:none}.nav a:hover,.nav a.on{background:rgba(91,94,244,.1);color:#5B5EF4}</style></head><body>
<div class="nav"><a href="dashboard.php">📊 Dashboard</a><a href="playlist.php">📋 Playlists</a><a href="schedule.php" class="on">📅 Schedule</a><a href="settings.php">⚙️ Settings</a><a href="player.php" target="_blank">🖥️ Watch</a><a href="logout.php">🚪 Logout</a></div>
<?php showFlash();?>
<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:20px"><h1 style="font-size:22px;font-weight:800">📅 Schedule</h1><button class="btn" onclick="document.getElementById('am').classList.add('show')">➕ Add</button></div>
<div class="card"><?php if(empty($scs)):?><p style="text-align:center;padding:30px;color:#495057">No schedules. Active playlist plays 24/7.</p>
<?php else:foreach($scs as $s):?><div class="si"><div style="min-width:90px;padding:4px 10px;background:rgba(91,94,244,.1);color:#5B5EF4;border-radius:6px;font-size:10px;font-weight:700;text-align:center"><?php echo $s['day_of_week']>=0?$days[$s['day_of_week']]:'Everyday';?></div><div style="flex:1"><div style="font-size:13px;font-weight:600">🕐 <?php echo $s['start_time'].' - '.$s['end_time'];?></div><div style="font-size:11px;color:#495057">📋 <?php echo htmlspecialchars($s['pname']);?></div></div><form method="POST" onsubmit="return confirm('Delete?')"><input type="hidden" name="action" value="delete_schedule"><input type="hidden" name="schedule_id" value="<?php echo $s['id'];?>"><button class="btn btn-red" style="padding:4px 10px;font-size:10px">🗑</button></form></div><?php endforeach;endif;?></div>
<div class="modal" id="am"><div class="modal-box"><h3 style="margin-bottom:16px">➕ Add Schedule</h3><form method="POST"><input type="hidden" name="action" value="add_schedule"><div class="fg"><label>Playlist</label><select name="playlist_id" required><option value="">Select...</option><?php foreach($pls as $p):?><option value="<?php echo $p['id'];?>"><?php echo htmlspecialchars($p['name']);?></option><?php endforeach;?></select></div><div class="fg"><label>Day</label><select name="day_of_week"><option value="-1">Everyday</option><?php foreach($days as $i=>$d):?><option value="<?php echo $i;?>"><?php echo $d;?></option><?php endforeach;?></select></div><div class="fg2"><div class="fg"><label>Start</label><input type="time" name="start_time" required></div><div class="fg"><label>End</label><input type="time" name="end_time" required></div></div><div class="fg"><label>Date (optional)</label><input type="date" name="specific_date"></div><div class="fg"><label><input type="checkbox" name="is_recurring" checked> Weekly</label></div><div class="acts"><button type="button" class="btn btn-gray" onclick="this.closest('.modal').classList.remove('show')">Cancel</button><button class="btn">Add</button></div></form></div></div></body></html>
SCHEOF

# SETTINGS PAGE
cat > /var/www/tv/public/settings.php << 'SETEOF'
<?php
ini_set('display_errors',1);error_reporting(E_ALL);session_start();
if(!isset($_SESSION['logged_in'])||$_SESSION['logged_in']!==true){header('Location: login.php');exit;}
$db=new SQLite3('/var/www/tv/data/tv.db');$db->busyTimeout(5000);
function gs($k){global $db;$s=$db->prepare('SELECT setting_value FROM settings WHERE setting_key=:k');$s->bindValue(':k',$k);$r=$s->execute();$row=$r->fetchArray(SQLITE3_ASSOC);return $row?$row['setting_value']:'';}
function ss($k,$v){global $db;$s=$db->prepare('INSERT OR REPLACE INTO settings (setting_key,setting_value) VALUES (:k,:v)');$s->bindValue(':k',$k);$s->bindValue(':v',$v);$s->execute();}
$fm='';
if($_SERVER['REQUEST_METHOD']==='POST'){$a=$_POST['action']??'';
if($a==='update_channel'){$n=trim($_POST['channel_name']??'');if($n)ss('channel_name',$n);
if(isset($_FILES['channel_logo'])&&$_FILES['channel_logo']['error']===0){$ext=strtolower(pathinfo($_FILES['channel_logo']['name'],PATHINFO_EXTENSION));if(in_array($ext,['jpg','jpeg','png','gif','webp'])){$dir='/var/www/tv/public/assets/logos/';if(!is_dir($dir))mkdir($dir,0775,true);$old=gs('channel_logo');if($old&&file_exists($dir.$old))@unlink($dir.$old);$fn='logo_'.time().'.'.$ext;move_uploaded_file($_FILES['channel_logo']['tmp_name'],$dir.$fn);ss('channel_logo',$fn);}}$fm='✅ Saved!';}
if($a==='remove_logo'){$old=gs('channel_logo');$dir='/var/www/tv/public/assets/logos/';if($old&&file_exists($dir.$old))@unlink($dir.$old);ss('channel_logo','');$fm='✅ Logo removed!';}
if($a==='change_password'){$cur=$_POST['current_password']??'';$new=$_POST['new_password']??'';$conf=$_POST['confirm_password']??'';$user=$db->querySingle("SELECT * FROM users WHERE id={$_SESSION['user_id']}",true);if(!password_verify($cur,$user['password']))$fm='❌ Wrong password!';elseif($new!==$conf)$fm='❌ No match!';elseif(strlen($new)<4)$fm='❌ Min 4 chars!';else{$h=password_hash($new,PASSWORD_DEFAULT);$s=$db->prepare('UPDATE users SET password=:p WHERE id=:i');$s->bindValue(':p',$h);$s->bindValue(':i',$_SESSION['user_id']);$s->execute();$fm='✅ Password changed!';}}}
$cn=gs('channel_name')?:'My TV Station';$cl=gs('channel_logo');$db->close();$hl=$cl&&file_exists('/var/www/tv/public/assets/logos/'.$cl);
?><!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Settings</title><link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600;700;800&display=swap" rel="stylesheet"><style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:'Inter',sans-serif;background:#06070A;color:#F1F3F5;min-height:100vh;padding:20px}.btn{padding:8px 16px;background:#5B5EF4;color:#fff;border:none;border-radius:8px;font-size:12px;font-weight:600;cursor:pointer;font-family:'Inter',sans-serif}.btn:hover{background:#4A4DD4}.btn-red{background:#EF4444}.card{background:#12141A;border:1px solid rgba(255,255,255,.05);border-radius:12px;padding:20px;margin-bottom:16px}.fg{margin-bottom:14px}.fg label{display:block;color:#868E96;font-size:12px;margin-bottom:4px;font-weight:600}.fg input{width:100%;padding:10px;background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.08);border-radius:8px;color:#fff;font-size:13px;outline:none;font-family:'Inter',sans-serif}.fg input:focus{border-color:#5B5EF4}.fg input[type=file]{color:#868E96}.grid{display:grid;grid-template-columns:1fr 1fr;gap:16px}.flash{padding:12px;border-radius:8px;margin-bottom:16px;font-size:13px;font-weight:600;background:rgba(91,94,244,.08);color:#5B5EF4;border:1px solid rgba(91,94,244,.15)}.ib{background:rgba(91,94,244,.04);border:1px solid rgba(91,94,244,.08);border-radius:10px;padding:14px;font-size:12px;color:#868E96;line-height:1.8}.ib code{background:rgba(255,255,255,.06);padding:2px 6px;border-radius:4px;color:#5B5EF4;font-size:11px}.nav{margin-bottom:16px;display:flex;gap:8px;flex-wrap:wrap}.nav a{padding:6px 14px;background:rgba(255,255,255,.04);border-radius:8px;color:#868E96;font-size:12px;font-weight:500;text-decoration:none}.nav a:hover,.nav a.on{background:rgba(91,94,244,.1);color:#5B5EF4}@media(max-width:768px){.grid{grid-template-columns:1fr}}</style></head><body>
<div class="nav"><a href="dashboard.php">📊 Dashboard</a><a href="playlist.php">📋 Playlists</a><a href="schedule.php">📅 Schedule</a><a href="settings.php" class="on">⚙️ Settings</a><a href="player.php" target="_blank">🖥️ Watch</a><a href="logout.php">🚪 Logout</a></div>
<?php if($fm):?><div class="flash"><?php echo $fm;?></div><?php endif;?>
<h1 style="font-size:22px;font-weight:800;margin-bottom:20px">⚙️ Settings</h1>
<div class="grid"><div>
<div class="card"><h3 style="margin-bottom:16px">📺 Channel</h3><form method="POST" enctype="multipart/form-data"><input type="hidden" name="action" value="update_channel"><div class="fg"><label>Channel Name</label><input type="text" name="channel_name" value="<?php echo htmlspecialchars($cn);?>" required></div><div class="fg"><label>Logo</label><?php if($hl):?><div style="margin-bottom:8px"><img src="/assets/logos/<?php echo htmlspecialchars($cl);?>" style="width:60px;height:60px;border-radius:10px;object-fit:cover"></div><?php endif;?><input type="file" name="channel_logo" accept="image/*"></div><div style="display:flex;gap:8px"><button class="btn">💾 Save</button><?php if($hl):?><button type="submit" name="action" value="remove_logo" class="btn btn-red" onclick="return confirm('Remove?')">🗑 Remove Logo</button><?php endif;?></div><p style="font-size:10px;color:#495057;margin-top:8px">⚠ Restart AutoDJ after changes</p></form></div>
<div class="card"><h3 style="margin-bottom:16px">🔐 Password</h3><form method="POST"><input type="hidden" name="action" value="change_password"><div class="fg"><label>Current</label><input type="password" name="current_password" required></div><div class="fg"><label>New</label><input type="password" name="new_password" required></div><div class="fg"><label>Confirm</label><input type="password" name="confirm_password" required></div><button class="btn">🔐 Change</button></form></div></div>
<div><div class="card"><h3 style="margin-bottom:16px">🌐 Stream URLs</h3><div class="ib"><strong>HLS:</strong><br><code>http://<?php echo $_SERVER['HTTP_HOST'];?>/hls/stream.m3u8</code><br><br><strong>Player:</strong><br><code>http://<?php echo $_SERVER['HTTP_HOST'];?>/player.php</code><br><br><strong>Embed:</strong><br><code>&lt;iframe src="http://<?php echo $_SERVER['HTTP_HOST'];?>/player.php" width="800" height="450"&gt;&lt;/iframe&gt;</code><br><br><strong>OBS Server:</strong><br><code>rtmp://<?php echo $_SERVER['HTTP_HOST'];?>/live</code><br><strong>OBS Key:</strong> <code>mystream</code></div></div></div></div></body></html>
SETEOF

# PLAYER PAGE
cat > /var/www/tv/public/player.php << 'PLAYEOF'
<?php require_once 'config.php';$cn=getSetting('channel_name')?:'My TV Station';$cl=getSetting('channel_logo');$hl=$cl&&file_exists(LOGO_PATH.$cl);?><!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title><?php echo htmlspecialchars($cn);?> Live</title><script src="https://cdn.jsdelivr.net/npm/hls.js@1.4.14/dist/hls.min.js"></script><style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:'Segoe UI',sans-serif;background:#000;color:#fff;height:100vh;display:flex;flex-direction:column;overflow:hidden}.hdr{display:flex;align-items:center;gap:12px;padding:10px 20px;background:rgba(10,10,10,.95);border-bottom:1px solid rgba(255,255,255,.06);flex-shrink:0}.hl{width:34px;height:34px;border-radius:8px;overflow:hidden;background:linear-gradient(135deg,#5B5EF4,#8B5CF6);display:flex;align-items:center;justify-content:center;font-size:16px;flex-shrink:0}.hl img{width:100%;height:100%;object-fit:cover}.hdr h1{font-size:15px;font-weight:700}.lp{margin-left:auto;display:flex;align-items:center;gap:6px;padding:5px 14px;border-radius:100px;font-size:11px;font-weight:800;letter-spacing:1px}.lp.live{background:#EF4444;animation:lpa 2s infinite}.lp.off{background:rgba(255,255,255,.08);color:rgba(255,255,255,.3)}.lp.con{background:rgba(245,158,11,.8)}@keyframes lpa{0%,100%{opacity:1}50%{opacity:.7}}.ld{width:6px;height:6px;border-radius:50%;background:#fff}.pw{flex:1;display:flex;align-items:center;justify-content:center;background:#000;position:relative}video{width:100%;height:100%;object-fit:contain}.wm{position:absolute;top:14px;right:14px;opacity:.4;z-index:5;pointer-events:none}.wm img{width:48px;height:48px;border-radius:8px;object-fit:cover}.ov{position:absolute;inset:0;display:none;flex-direction:column;align-items:center;justify-content:center;gap:16px;background:#000;z-index:3}.ov.show{display:flex}.ov .oi{font-size:64px;opacity:.15}.rb{padding:10px 28px;background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.1);border-radius:10px;color:rgba(255,255,255,.5);font-size:13px;cursor:pointer}.um{position:absolute;inset:0;display:none;align-items:center;justify-content:center;background:rgba(0,0,0,.5);z-index:8;cursor:pointer}.um.show{display:flex}.ub{background:rgba(0,0,0,.7);border:1px solid rgba(255,255,255,.1);border-radius:16px;padding:24px 36px;text-align:center}.ub .icon{font-size:42px;margin-bottom:10px}</style></head>
<body><div class="hdr"><div class="hl"><?php if($hl):?><img src="<?php echo LOGO_URL.htmlspecialchars($cl);?>"><?php else:?>📺<?php endif;?></div><h1><?php echo htmlspecialchars($cn);?></h1><div class="lp con" id="lp"><span class="ld"></span><span id="lt">CONNECTING</span></div></div>
<div class="pw"><?php if($hl):?><div class="wm"><img src="<?php echo LOGO_URL.htmlspecialchars($cl);?>"></div><?php endif;?><video id="v" autoplay playsinline muted></video><div class="ov" id="ov"><div class="oi">📺</div><h2 style="font-size:20px;color:rgba(255,255,255,.3)"><?php echo htmlspecialchars($cn);?></h2><p style="color:rgba(255,255,255,.15)">Auto-reconnecting...</p><button class="rb" onclick="connect()">🔄 Retry</button></div><div class="um" id="um" onclick="v.muted=false;um.classList.remove('show');v.play().catch(function(){})"><div class="ub"><div class="icon">🔊</div><p style="color:rgba(255,255,255,.6)">Click to unmute</p></div></div></div>
<script>var v=document.getElementById('v'),ov=document.getElementById('ov'),lp=document.getElementById('lp'),lt=document.getElementById('lt'),um=document.getElementById('um'),hls=null,playing=false,rc=0;function st(s){lp.className='lp '+s;if(s==='live'){lt.textContent='LIVE';ov.classList.remove('show');v.style.display='block';playing=true;if(v.muted)um.classList.add('show')}else if(s==='off'){lt.textContent='OFFLINE';ov.classList.add('show');playing=false}else lt.textContent='CONNECTING'}function kill(){if(hls){hls.destroy();hls=null}}function connect(){kill();st('con');fetch('/hls/stream.m3u8',{method:'HEAD',cache:'no-store'}).then(function(r){if(!r.ok)throw'';startHLS()}).catch(function(){st('off');retry()})}function startHLS(){if(!Hls.isSupported()){v.src='/hls/stream.m3u8';v.onplaying=function(){st('live')};v.onerror=function(){st('off');retry()};return}hls=new Hls({enableWorker:true,liveSyncDurationCount:2,liveMaxLatencyDurationCount:5,maxBufferLength:8,fragLoadingTimeOut:20000,fragLoadingMaxRetry:8,manifestLoadingMaxRetry:8});hls.loadSource('/hls/stream.m3u8');hls.attachMedia(v);hls.on(Hls.Events.MANIFEST_PARSED,function(){rc=0;v.play().catch(function(){})});hls.on(Hls.Events.FRAG_LOADED,function(){if(!playing)st('live');rc=0});hls.on(Hls.Events.ERROR,function(e,d){if(d.fatal){if(d.type===Hls.ErrorTypes.MEDIA_ERROR)hls.recoverMediaError();else{st('off');kill();retry()}}});v.onplaying=function(){st('live')}}function retry(){rc++;setTimeout(connect,Math.min(2000+rc*500,10000))}setInterval(function(){if(!playing)fetch('/hls/stream.m3u8',{method:'HEAD',cache:'no-store'}).then(function(r){if(r.ok)connect()}).catch(function(){});else{if(v.paused)v.play().catch(function(){});if(hls&&v.duration&&isFinite(v.duration)&&v.duration-v.currentTime>12)v.currentTime=v.duration-2}},6000);connect()</script></body></html>
PLAYEOF

echo -e "${GREEN}  ✅ All pages created${NC}"

# ============================================
# STEP 9: CREATE AUTODJ
# ============================================
echo -e "${YELLOW}[9/12] 🎵 Creating AutoDJ...${NC}"

cat > /var/www/tv/scripts/start_stream.sh << 'SSEOF'
#!/bin/bash
pkill -f "autodj.php" 2>/dev/null;pkill -f "ffmpeg.*stream" 2>/dev/null;sleep 2
rm -f /var/www/tv/hls/*.ts /var/www/tv/hls/*.m3u8 /tmp/autodj.lock /tmp/autodj_state.json 2>/dev/null
mkdir -p /var/www/tv/hls;chown www-data:www-data /var/www/tv/hls
nohup php /var/www/tv/scripts/autodj.php >> /var/log/autodj.log 2>&1 &
echo "AutoDJ PID: $!"
SSEOF
chmod +x /var/www/tv/scripts/start_stream.sh

cat > /var/www/tv/scripts/autodj.php << 'ADJEOF'
#!/usr/bin/php
<?php
define('DB_PATH','/var/www/tv/data/tv.db');define('HLS_PATH','/var/www/tv/hls');define('LOGO_PATH','/var/www/tv/public/assets/logos/');define('LOCK_FILE','/tmp/autodj.lock');define('LOG_FILE','/var/log/autodj.log');define('STATE_FILE','/tmp/autodj_state.json');
function logMsg($m){$t=date('Y-m-d H:i:s');file_put_contents(LOG_FILE,"[$t] $m\n",FILE_APPEND);echo"[$t] $m\n";}
if(file_exists(LOCK_FILE)){$p=(int)file_get_contents(LOCK_FILE);if($p&&file_exists("/proc/$p")){logMsg("Running:$p");exit(1);}@unlink(LOCK_FILE);}file_put_contents(LOCK_FILE,getmypid());
function cleanup(){@unlink(LOCK_FILE);@unlink(STATE_FILE);shell_exec('pkill -f "ffmpeg.*stream_seg" 2>/dev/null');shell_exec('pkill -f "ffmpeg.*stream.m3u8" 2>/dev/null');logMsg("Cleanup");}register_shutdown_function('cleanup');
if(function_exists('pcntl_signal')){pcntl_signal(SIGTERM,function(){cleanup();exit;});pcntl_signal(SIGINT,function(){cleanup();exit;});}
function saveState($p,$i){file_put_contents(STATE_FILE,json_encode(['pid'=>$p,'idx'=>$i,'ts'=>time()]));}
function getDB(){$db=new SQLite3(DB_PATH);$db->busyTimeout(5000);$db->exec('PRAGMA journal_mode=WAL');return $db;}
function gs($k){try{$db=getDB();$s=$db->prepare('SELECT setting_value FROM settings WHERE setting_key=:k');$s->bindValue(':k',$k);$r=$s->execute();$row=$r->fetchArray(SQLITE3_ASSOC);$db->close();return $row?$row['setting_value']:'';}catch(Exception $e){return'';}}
function isOBS(){try{$db=getDB();$v=$db->querySingle('SELECT is_obs_live FROM obs_config WHERE id=1');$db->close();return(bool)$v;}catch(Exception $e){return false;}}
function getSchPl(){try{$db=getDB();$now=date('H:i');$dow=(int)date('w');$today=date('Y-m-d');$s=$db->prepare("SELECT playlist_id FROM schedule WHERE specific_date=:t AND start_time<=:n AND end_time>:n LIMIT 1");$s->bindValue(':t',$today);$s->bindValue(':n',$now);$r=$s->execute();$row=$r->fetchArray(SQLITE3_ASSOC);if($row){$db->close();return(int)$row['playlist_id'];}$s=$db->prepare("SELECT playlist_id FROM schedule WHERE (day_of_week=:d OR day_of_week=-1) AND is_recurring=1 AND start_time<=:n AND end_time>:n LIMIT 1");$s->bindValue(':d',$dow);$s->bindValue(':n',$now);$r=$s->execute();$row=$r->fetchArray(SQLITE3_ASSOC);$db->close();return $row?(int)$row['playlist_id']:null;}catch(Exception $e){return null;}}
function getActPl(){try{$db=getDB();$v=$db->querySingle('SELECT id FROM playlists WHERE is_active=1');$db->close();return $v?(int)$v:null;}catch(Exception $e){return null;}}
function getVids($p){$v=[];try{$db=getDB();$r=$db->query("SELECT * FROM videos WHERE playlist_id=$p ORDER BY sort_order ASC,id ASC");while($row=$r->fetchArray(SQLITE3_ASSOC))$v[]=$row;$db->close();}catch(Exception $e){}return $v;}
function getVid($id){try{$db=getDB();$r=$db->querySingle("SELECT * FROM videos WHERE id=$id",true);$db->close();return $r?:null;}catch(Exception $e){return null;}}
function getLogo(){$l=gs('channel_logo');return($l&&file_exists(LOGO_PATH.$l))?LOGO_PATH.$l:'';}
function getLogoSz(){return max(20,min(300,(int)(gs('logo_size')?:80)));}
function getLogoOp(){return round(max(5,min(100,(int)(gs('logo_opacity')?:70)))/100,2);}
function getLogoPad(){return max(5,min(100,(int)(gs('logo_padding')?:20)));}
function getLogoPos(){$cx=(int)(gs('logo_x')?:-1);$cy=(int)(gs('logo_y')?:-1);if($cx>=0&&$cy>=0)return"$cx:$cy";$pos=gs('logo_position')?:'top-right';$pad=getLogoPad();switch($pos){case'top-left':return"$pad:$pad";case'top-center':return"(W-w)/2:$pad";case'top-right':return"W-w-$pad:$pad";case'mid-left':return"$pad:(H-h)/2";case'center':return"(W-w)/2:(H-h)/2";case'mid-right':return"W-w-$pad:(H-h)/2";case'bottom-left':return"$pad:H-h-$pad";case'bottom-center':return"(W-w)/2:H-h-$pad";case'bottom-right':return"W-w-$pad:H-h-$pad";default:return"W-w-$pad:$pad";}}
function probe($url){$i=['has_video'=>true,'has_audio'=>true];$o=@shell_exec("ffprobe -v quiet -print_format json -show_streams -timeout 10000000 ".escapeshellarg($url)." 2>/dev/null");if(!$o)return $i;$d=@json_decode($o,true);if(!$d||!isset($d['streams']))return $i;$i['has_video']=false;$i['has_audio']=false;foreach($d['streams'] as $s){if($s['codec_type']==='video')$i['has_video']=true;if($s['codec_type']==='audio')$i['has_audio']=true;}logMsg("Probe:".($i['has_video']?'V':'-').($i['has_audio']?'A':'-'));return $i;}
function buildCmd($url,$logo,$mi){$ho=HLS_PATH.'/stream.m3u8';$sp=HLS_PATH.'/stream_seg%05d.ts';$hl=!empty($logo)&&file_exists($logo);$ha=$mi['has_audio'];$in="ffmpeg -y -re -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 -timeout 30000000 -i ".escapeshellarg($url)." ";if(!$ha)$in.="-f lavfi -i anullsrc=r=44100:cl=stereo ";if($hl)$in.="-i ".escapeshellarg($logo)." ";$out="-c:v libx264 -preset superfast -tune zerolatency -b:v 1800k -maxrate 2000k -bufsize 3000k -r 25 -g 50 -keyint_min 25 -sc_threshold 0 -c:a aac -b:a 128k -ar 44100 -ac 2 -f hls -hls_time 2 -hls_list_size 10 -hls_delete_threshold 5 -hls_flags delete_segments+append_list+discont_start+omit_endlist+temp_file -hls_allow_cache 0 -hls_segment_type mpegts -hls_segment_filename ".escapeshellarg($sp)." ".escapeshellarg($ho);if($hl){$lp2=getLogoPos();$lsz=getLogoSz();$lop=getLogoOp();$li=$ha?1:2;return $in."-filter_complex \"[0:v]scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:black,format=yuv420p[bg];[$li:v]scale=$lsz:-1,format=rgba,colorchannelmixer=aa=$lop[logo];[bg][logo]overlay=$lp2[vout]\" -map \"[vout]\" ".($ha?"-map 0:a:0 ":"-map 1:a:0 -shortest ").$out;}return $in."-vf \"scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:black,format=yuv420p\" ".($ha?"-map 0:v:0 -map 0:a:0 ":"-map 0:v:0 -map 1:a:0 -shortest ").$out;}
function basicCmd($url){$ho=HLS_PATH.'/stream.m3u8';$sp=HLS_PATH.'/stream_seg%05d.ts';return"ffmpeg -y -re -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 -timeout 30000000 -i ".escapeshellarg($url)." -f lavfi -i anullsrc=r=44100:cl=stereo -vf \"scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:black,format=yuv420p\" -map 0:v:0 -map 0:a:0? -map 1:a:0 -c:v libx264 -preset superfast -tune zerolatency -b:v 1800k -maxrate 2000k -bufsize 3000k -r 25 -g 50 -keyint_min 25 -sc_threshold 0 -c:a aac -b:a 128k -ar 44100 -ac 2 -shortest -f hls -hls_time 2 -hls_list_size 10 -hls_delete_threshold 5 -hls_flags delete_segments+append_list+discont_start+omit_endlist+temp_file -hls_allow_cache 0 -hls_segment_type mpegts -hls_segment_filename ".escapeshellarg($sp)." ".escapeshellarg($ho);}
function playVideo($url,$title){if(!is_dir(HLS_PATH))mkdir(HLS_PATH,0755,true);logMsg("PLAYING: $title");$mi=probe($url);$logo=getLogo();$cmd=buildCmd($url,$logo,$mi);$desc=[0=>['pipe','r'],1=>['file','/tmp/ffmpeg_stdout.log','w'],2=>['file','/tmp/ffmpeg_autodj.log','w']];$proc=proc_open($cmd,$desc,$pipes);if(!is_resource($proc)){$cmd=buildCmd($url,'',$mi);$proc=proc_open($cmd,$desc,$pipes);if(!is_resource($proc)){$cmd=basicCmd($url);$proc=proc_open($cmd,$desc,$pipes);if(!is_resource($proc))return false;}}if(isset($pipes[0])&&is_resource($pipes[0]))fclose($pipes[0]);$ho=HLS_PATH.'/stream.m3u8';$w=0;while($w<50){if(file_exists($ho)&&filesize($ho)>10){$ts=glob(HLS_PATH.'/stream_seg*.ts');if($ts&&count($ts)>0){logMsg("HLS OK");break;}}sleep(1);$w++;$st=proc_get_status($proc);if(!$st['running']){if(!empty($logo)){proc_close($proc);$cmd=buildCmd($url,'',$mi);$proc=proc_open($cmd,$desc,$p2);if(is_resource($proc)){if(isset($p2[0]))fclose($p2[0]);$logo='';$w=0;continue;}}proc_close($proc);$cmd=basicCmd($url);$proc=proc_open($cmd,$desc,$p3);if(is_resource($proc)){if(isset($p3[0]))fclose($p3[0]);$w=0;continue;}return false;}}if($w>=50){proc_terminate($proc);proc_close($proc);return false;}$hb=time();$start=time();while(true){if(function_exists('pcntl_signal_dispatch'))pcntl_signal_dispatch();$st=proc_get_status($proc);if(!$st['running']){$t=time()-$start;logMsg("Done: $title (".floor($t/60)."m)");break;}if(isOBS()){proc_terminate($proc);sleep(1);proc_close($proc);return'obs';}if(time()-$hb>=60){$hb=time();logMsg("Playing: $title ".floor((time()-$start)/60)."m");}sleep(2);}proc_close($proc);return true;}
logMsg("=== AutoDJ START ===");logMsg("Logo:".(getLogo()?:'NONE'));
if(!is_dir(HLS_PATH))mkdir(HLS_PATH,0755,true);foreach(array_merge(glob(HLS_PATH.'/*.ts')?:[],glob(HLS_PATH.'/*.m3u8')?:[])as $f)@unlink($f);
$lc=0;$lpid=null;$lvids=[];$ci=0;
while(true){if(function_exists('pcntl_signal_dispatch'))pcntl_signal_dispatch();$lc++;
if(isOBS()){if($lc%12==1)logMsg("OBS-wait");sleep(5);continue;}
$pid=getSchPl()?:getActPl();if(!$pid){if($lc%6==1)logMsg("No playlist");sleep(10);continue;}
$vids=getVids($pid);if(empty($vids)){if($lc%6==1)logMsg("Empty");sleep(10);continue;}
$total=count($vids);$ids=array_column($vids,'id');
if($pid!==$lpid){logMsg("=== PL:$pid $total vids ===");$lpid=$pid;$lvids=$ids;$ci=0;}
$new=array_diff($ids,$lvids);if(!empty($new)){logMsg(count($new)." NEW");$lvids=$ids;}
$gone=array_diff($lvids,$ids);if(!empty($gone)){$lvids=$ids;if($ci>=$total)$ci=0;}
$lvids=$ids;if($ci>=$total){$ci=0;logMsg("LOOP");}
$v=$vids[$ci];logMsg(">>> ".($ci+1)."/$total: {$v['title']}");
$result=playVideo($v['url'],$v['title']);
if($result==='obs'){while(isOBS()){sleep(5);}continue;}
if($result===false){$ci++;sleep(2);continue;}
$ci++;saveState($pid,$ci);
$fv=getVids($pid);$fi=array_column($fv,'id');if(array_diff($fi,$lvids)){$lvids=$fi;$total=count($fv);}
$np=getSchPl()?:getActPl();if($np&&$np!=$pid){$lpid=null;$ci=0;}
sleep(1);}
?>
ADJEOF
chmod +x /var/www/tv/scripts/autodj.php
echo -e "${GREEN}  ✅ AutoDJ created${NC}"

# STEP 10
echo -e "${YELLOW}[10/12] 🔒 Permissions...${NC}"
chown -R www-data:www-data /var/www/tv
chmod -R 755 /var/www/tv
chmod -R 775 /var/www/tv/hls /var/www/tv/data /var/www/tv/public/assets/logos
chmod 664 /var/www/tv/data/tv.db
touch /var/log/autodj.log
chown www-data:www-data /var/log/autodj.log
echo -e "${GREEN}  ✅ Done${NC}"

# STEP 11
echo -e "${YELLOW}[11/12] 🔄 Auto-start service...${NC}"
cat > /etc/systemd/system/autodj.service << SVCEOF
[Unit]
Description=TV AutoDJ
After=network.target nginx.service
[Service]
Type=simple
User=root
ExecStart=/usr/bin/php /var/www/tv/scripts/autodj.php
ExecStop=/usr/bin/pkill -f autodj.php
Restart=always
RestartSec=10
StandardOutput=append:/var/log/autodj.log
StandardError=append:/var/log/autodj.log
[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable autodj > /dev/null 2>&1
echo -e "${GREEN}  ✅ Done${NC}"

# STEP 12
echo -e "${YELLOW}[12/12] 🚀 Starting...${NC}"
systemctl restart php${PHP_VER}-fpm
nginx -t > /dev/null 2>&1 && systemctl restart nginx
ufw allow 80/tcp > /dev/null 2>&1
ufw allow 443/tcp > /dev/null 2>&1
ufw allow 1935/tcp > /dev/null 2>&1
ufw allow ssh > /dev/null 2>&1
echo -e "${GREEN}  ✅ All running${NC}"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     ✅  INSTALLATION COMPLETE!  ✅           ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${WHITE}📺 Dashboard:  ${CYAN}http://${SERVER_IP}${NC}"
echo -e "${WHITE}🖥️  Player:     ${CYAN}http://${SERVER_IP}/player.php${NC}"
echo -e "${WHITE}📡 HLS:        ${CYAN}http://${SERVER_IP}/hls/stream.m3u8${NC}"
echo ""
echo -e "${WHITE}🔐 Login:      ${CYAN}admin / 123456${NC}"
echo ""
echo -e "${WHITE}🎥 OBS Server: ${CYAN}rtmp://${SERVER_IP}/live${NC}"
echo -e "${WHITE}🎥 OBS Key:    ${CYAN}mystream${NC}"
echo ""
