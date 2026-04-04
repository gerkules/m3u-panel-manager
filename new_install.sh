#!/bin/bash

# Root check
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit
fi

echo "--- IPTV Manager Installer (Hybrid Edition) ---"
echo "Select language / Выберите язык:"
echo "1) Russian (RU)"
echo "2) English (EN)"
read -p "Choice (1-2): " LANG_CHOICE

# Install system packages
apt update && apt install -y python3 python3-pip python3-venv sqlite3

# Create folder structure
mkdir -p /opt/iptv_manager/playlists
mkdir -p /opt/iptv_manager/templates
cd /opt/iptv_manager

# Setup Virtual Environment
python3 -m venv venv
./venv/bin/pip install flask flask-sqlalchemy flask-login werkzeug

# --- GENERATE APP.PY ---
cat <<'EOF' > app.py
# -*- coding: utf-8 -*-
from flask import Flask, request, render_template, redirect, url_for, Response, send_file
from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager, UserMixin, login_user, login_required, logout_user, current_user
from werkzeug.security import check_password_hash, generate_password_hash
from datetime import datetime
import os

app = Flask(__name__)
app.config['SECRET_KEY'] = 'gerkules-master-key'
app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:////opt/iptv_manager/iptv.db'
app.config['PLAYLIST_FOLDER'] = '/opt/iptv_manager/playlists'
app.config['DB_PATH'] = '/opt/iptv_manager/iptv.db'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

db = SQLAlchemy(app)
login_manager = LoginManager(app)
login_manager.login_view = 'login'

class Settings(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    key = db.Column(db.String(50), unique=True)
    value = db.Column(db.String(100))

class Admin(db.Model, UserMixin):
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(50), unique=True, nullable=False)
    password = db.Column(db.String(200), nullable=False)

class Channel(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100))
    group = db.Column(db.String(50))
    url = db.Column(db.String(500))

class Client(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(50))
    token = db.Column(db.String(100), unique=True)
    access_type = db.Column(db.String(10), default='file')
    playlist_file = db.Column(db.String(100))
    expire_date = db.Column(db.Date)

@login_manager.user_loader
def load_user(user_id): return Admin.query.get(int(user_id))

@app.context_processor
def inject_vars():
    return {'unlim_val': datetime.strptime('2099-12-31', '%Y-%m-%d').date()}

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        user = Admin.query.filter_by(username=request.form.get('username')).first()
        if user and check_password_hash(user.password, request.form.get('password')):
            login_user(user)
            return redirect(url_for('admin'))
    return render_template('login.html')

@app.route('/admin', methods=['GET', 'POST'])
@login_required
def admin():
    if request.method == 'POST':
        try:
            d = request.form.get('expire_date') or '2099-12-31'
            db.session.add(Client(
                username=request.form['username'],
                token=request.form['token'],
                access_type=request.form['access_type'],
                playlist_file=request.form.get('playlist_file'),
                expire_date=datetime.strptime(d, '%Y-%m-%d').date()
            ))
            db.session.commit()
        except: db.session.rollback()
        return redirect(url_for('admin'))
    users = Client.query.order_by(Client.id.desc()).all()
    files = [f for f in os.listdir(app.config['PLAYLIST_FOLDER']) if f.endswith(('.m3u', '.m3u8'))]
    return render_template('admin.html', users=users, files=files)

@app.route('/edit/<int:id>', methods=['GET', 'POST'])
@login_required
def edit_user(id):
    u = Client.query.get_or_404(id)
    if request.method == 'POST':
        try:
            u.username, u.token, u.access_type = request.form['username'], request.form['token'], request.form['access_type']
            u.playlist_file = request.form.get('playlist_file')
            u.expire_date = datetime.strptime(request.form['expire_date'], '%Y-%m-%d').date()
            db.session.commit()
            return redirect(url_for('admin'))
        except: db.session.rollback()
    files = [f for f in os.listdir(app.config['PLAYLIST_FOLDER']) if f.endswith(('.m3u', '.m3u8'))]
    return render_template('edit.html', user=u, files=files)

@app.route('/delete/<int:id>')
@login_required
def delete_user(id):
    u = Client.query.get(id); (db.session.delete(u), db.session.commit()) if u else None
    return redirect(url_for('admin'))

@app.route('/channels', methods=['GET', 'POST'])
@login_required
def channels_man():
    if request.method == 'POST':
        db.session.add(Channel(name=request.form['name'], group=request.form['group'], url=request.form['url']))
        db.session.commit()
        return redirect(url_for('channels_man'))
    chs = Channel.query.all()
    return render_template('channels.html', channels=chs)

@app.route('/channel/edit/<int:id>', methods=['GET', 'POST'])
@login_required
def edit_channel(id):
    ch = Channel.query.get_or_404(id)
    if request.method == 'POST':
        ch.name, ch.group, ch.url = request.form['name'], request.form['group'], request.form['url']
        db.session.commit()
        return redirect(url_for('channels_man'))
    return render_template('edit_ch.html', ch=ch)

@app.route('/channel/delete/<int:id>')
@login_required
def delete_channel(id):
    ch = Channel.query.get(id); (db.session.delete(ch), db.session.commit()) if ch else None
    return redirect(url_for('channels_man'))

@app.route('/play/<int:ch_id>')
def play_stream(ch_id):
    u = Client.query.filter_by(token=request.args.get('token')).first()
    if u and u.expire_date >= datetime.now().date():
        ch = Channel.query.get_or_404(ch_id)
        return redirect(ch.url)
    return "Denied", 403

@app.route('/backup')
@login_required
def backup(): return send_file(app.config['DB_PATH'], as_attachment=True, download_name="iptv_backup.db")

@app.route('/restore', methods=['POST'])
@login_required
def restore():
    file = request.files.get('backup_file')
    if file and file.filename.endswith('.db'):
        db.session.remove(); db.engine.dispose()
        file.save(app.config['DB_PATH'])
        os.chmod(app.config['DB_PATH'], 0o666)
        return '<html><script>alert("OK!"); window.location.href="/admin";</script></html>'
    return "Error", 400

@app.route('/settings', methods=['GET', 'POST'])
@login_required
def settings():
    p_set = Settings.query.filter_by(key='port').first()
    if request.method == 'POST':
        new_p = request.form.get('port', '8090')
        if p_set: p_set.value = new_p
        else: db.session.add(Settings(key='port', value=new_p))
        db.session.commit()
        return render_template('settings_ok.html', port=new_p)
    return render_template('settings.html', port=(p_set.value if p_set else "8090"))

@app.route('/get')
def get_playlist():
    token = request.args.get('token')
    u = Client.query.filter_by(token=token).first()
    if u and u.expire_date >= datetime.now().date():
        if u.access_type == 'file':
            p = os.path.join(app.config['PLAYLIST_FOLDER'], u.playlist_file)
            if os.path.exists(p):
                with open(p, 'r', encoding='utf-8') as f: return Response(f.read(), mimetype='text/plain')
        else:
            chs = Channel.query.all()
            m3u = "#EXTM3U\n"
            for c in chs:
                link = f"{request.host_url}play/{c.id}?token={token}"
                m3u += f'#EXTINF:-1 group-title="{c.group}",{c.name}\n{link}\n'
            return Response(m3u, mimetype='text/plain')
    return "Denied", 403

@app.route('/logout')
def logout(): logout_user(); return redirect(url_for('login'))

if __name__ == '__main__':
    with app.app_context():
        db.create_all()
        if not Admin.query.first():
            db.session.add(Admin(username='admin', password=generate_password_hash('admin')))
            db.session.commit()
        ps = Settings.query.filter_by(key='port').first()
        port = int(ps.value) if ps else 8090
    app.run(host='0.0.0.0', port=port)
EOF

# --- TRANSLATIONS ---
if [ "$LANG_CHOICE" == "1" ]; then
    L_TITLE="Управление"; L_SET="Настройки"; L_CHANNELS="Каналы"; L_BACKUP="Бэкап"; L_RESTORE="Восстановить"; L_OUT="Выход";
    L_NAME="Имя"; L_TOKEN="Токен"; L_FILE="Файл"; L_DATE="Срок"; L_ACT="Действие"; L_CREATE="Создать";
    L_UNLIM="Безлимит"; L_EDIT="Изменить"; L_DEL="Удалить"; L_TYPE="Доступ"; L_FILE_TYPE="Файл"; L_DB_TYPE="Каналы из БД";
    L_SAVE="Сохранить"; L_CH_NAME="Имя канала"; L_CH_GRP="Группа"; L_CH_URL="URL потока"; L_PORT="Порт панели";
    L_LOG_PASS="ЛОГИН ПАРОЛЬ"; L_CHOOSE="Обзор...";
else
    L_TITLE="Management"; L_SET="Settings"; L_CHANNELS="Channels"; L_BACKUP="Backup"; L_RESTORE="Restore"; L_OUT="Logout";
    L_NAME="Name"; L_TOKEN="Token"; L_FILE="File"; L_DATE="Expire"; L_ACT="Action"; L_CREATE="Create";
    L_UNLIM="Unlimited"; L_EDIT="Edit"; L_DEL="Delete"; L_TYPE="Access"; L_FILE_TYPE="File"; L_DB_TYPE="DB Channels";
    L_SAVE="Save"; L_CH_NAME="Chan Name"; L_CH_GRP="Group"; L_CH_URL="Stream URL"; L_PORT="Panel Port";
    L_LOG_PASS="USER PASS"; L_CHOOSE="Browse...";
fi

# --- TEMPLATES ---
cat <<EOF > templates/admin.html
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>IPTV Panel</title>
<style>
    body { font-family: sans-serif; background: #f0f2f5; padding: 20px; }
    .card { background: white; padding: 20px; border-radius: 12px; max-width: 1200px; margin: auto; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
    .btn { padding: 10px 20px; border-radius: 8px; text-decoration: none; color: white; cursor: pointer; border: none; font-size: 14px; font-weight: bold; display: inline-flex; align-items: center; gap: 8px; }
    form.add-form { background: #f8f9fa; padding: 15px; border-radius: 10px; display: flex; gap: 8px; margin: 20px 0; align-items: center; flex-wrap: wrap; }
    input, select { padding: 8px; border: 1px solid #ddd; border-radius: 6px; }
    table { width: 100%; border-collapse: collapse; }
    th, td { padding: 12px; border-bottom: 1px solid #eee; text-align: left; font-size: 14px; }
    th { background: #4a69bd; color: white; }
    .btn-settings { background: #a55eea; }
    .btn-backup { background: #27ae60; }
    .btn-restore { background: #f39c12; }
    .file-restore-wrapper { display: flex; border: 1px solid #ddd; border-radius: 8px; overflow: hidden; background: white; }
    .file-restore-wrapper input[type=file] { display: none; }
    .file-restore-label { padding: 8px 12px; background: #eee; cursor: pointer; font-size: 13px; color: #333; border-right: 1px solid #ddd; }
    .file-restore-name { padding: 8px 12px; font-size: 13px; color: #777; min-width: 100px; max-width: 150px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
</style>
</head><body><div class="card">
<div style="display:flex; justify-content:space-between; align-items:center;">
    <h2>$L_TITLE</h2>
    <div style="display:flex; gap:12px; align-items:center;">
        <a href="/channels" class="btn" style="background:#e67e22;">$L_CHANNELS</a>
        <a href="/settings" class="btn btn-settings">⚙️ $L_SET</a>
        <a href="/backup" class="btn btn-backup">$L_BACKUP</a>
        <form action="/restore" method="POST" enctype="multipart/form-data" style="display:flex; gap:8px; margin:0;">
            <div class="file-restore-wrapper">
                <label for="restore_file" class="file-restore-label">$L_CHOOSE</label>
                <input type="file" name="backup_file" id="restore_file" required onchange="document.getElementById('fn').innerText=this.files[0].name">
                <div class="file-restore-name" id="fn">Файл...</div>
            </div>
            <button type="submit" class="btn btn-restore">$L_RESTORE</button>
        </form>
        <a href="/logout" style="color:#e74c3c; text-decoration:none; font-weight:bold; font-size:16px; margin-left:10px;">$L_OUT</a>
    </div>
</div>
<form method="POST" class="add-form">
    <input type="text" name="username" placeholder="$L_NAME" required>
    <input type="text" name="token" placeholder="$L_TOKEN" required>
    <select name="access_type" onchange="document.getElementById('f_sel').disabled=(this.value=='db')">
        <option value="file">$L_FILE_TYPE</option>
        <option value="db">$L_DB_TYPE</option>
    </select>
    <select name="playlist_file" id="f_sel">
        <option value="">-- $L_FILE --</option>
        {% for file in files %}<option value="{{ file }}">{{ file }}</option>{% endfor %}
    </select>
    <input type="date" name="expire_date" id="d_add">
    <button type="button" onclick="document.getElementById('d_add').value='2099-12-31'" style="border:none; background:none; cursor:pointer; font-size:20px;">♾️</button>
    <button type="submit" class="btn" style="background:#2ecc71;">$L_CREATE</button>
</form>
<table>
    <tr><th>$L_NAME</th><th>URL</th><th>$L_FILE</th><th>$L_TYPE</th><th>$L_DATE</th><th>$L_ACT</th></tr>
    {% for user in users %}
    <tr>
        <td>{{ user.username }}</td>
        <td><code>{{ request.host_url }}get?token={{ user.token }}</code></td>
        <td><b style="color:#2980b9;">{{ user.playlist_file if user.access_type == 'file' else '---' }}</b></td>
        <td>{{ '$L_FILE_TYPE' if user.access_type == 'file' else '$L_DB_TYPE' }}</td>
        <td>{% if user.expire_date == unlim_val %}<span style="color:green">$L_UNLIM</span>{% else %}{{ user.expire_date }}{% endif %}</td>
        <td><a href="/edit/{{ user.id }}" style="color:#3498db; text-decoration:none; font-weight:bold;">$L_EDIT</a> |
            <a href="/delete/{{ user.id }}" style="color:#e74c3c; text-decoration:none; font-weight:bold;" onclick="return confirm('?')">X</a></td>
    </tr>
    {% endfor %}
</table>
</div></body></html>
EOF

cat <<EOF > templates/edit.html
<!DOCTYPE html><html><head><meta charset="UTF-8"><style>
    body { font-family: sans-serif; background: #f0f2f5; display: flex; justify-content: center; padding-top: 40px; }
    .card { background: white; padding: 25px; border-radius: 12px; width: 400px; box-shadow: 0 4px 15px rgba(0,0,0,0.1); }
    h2 { text-align: center; margin-bottom: 20px; color: #333; }
    label { font-size: 14px; color: #666; display: block; margin-top: 10px; }
    input, select { width: 100%; padding: 12px; margin: 8px 0; border: 1px solid #ddd; border-radius: 8px; box-sizing: border-box; font-size: 15px; }
    .btn-group { display: flex; gap: 8px; margin: 15px 0; }
    .btn-fast { flex: 1; padding: 10px; font-size: 13px; cursor: pointer; background: #f1f2f6; border: 1px solid #dfe4ea; border-radius: 8px; font-weight: 500; }
</style></head><body><div class="card">
<h2>Редактировать клиента</h2>
<form method="POST">
    <label>$L_NAME</label><input type="text" name="username" value="{{ user.username }}" required>
    <label>$L_TOKEN</label><input type="text" name="token" value="{{ user.token }}" required>
    <label>$L_TYPE</label>
    <select name="access_type">
        <option value="file" {% if user.access_type == 'file' %}selected{% endif %}>$L_FILE_TYPE</option>
        <option value="db" {% if user.access_type == 'db' %}selected{% endif %}>$L_DB_TYPE</option>
    </select>
    <label>$L_FILE</label>
    <select name="playlist_file">
        {% for file in files %}<option value="{{ file }}" {% if file == user.playlist_file %}selected{% endif %}>{{ file }}</option>{% endfor %}
    </select>
    <label>$L_DATE</label><input type="date" name="expire_date" id="exp_date" value="{{ user.expire_date }}" required>
    <div class="btn-group">
        <button type="button" class="btn-fast" onclick="addDays(30)">+30 дн</button>
        <button type="button" class="btn-fast" onclick="addDays(365)">+1 год</button>
        <button type="button" class="btn-fast" onclick="document.getElementById('exp_date').value='2099-12-31'">♾️ Безлим</button>
    </div>
    <button type="submit" style="background:#3498db; color:white; border:none; padding:14px; width:100%; border-radius:10px; font-weight:bold; cursor:pointer; font-size:16px;">$L_SAVE</button>
</form>
<a href="/admin" style="display:block; text-align:center; margin-top:20px; color:#999; text-decoration:none;">Отмена</a>
<script>
    function addDays(days) {
        let d = new Date();
        d.setDate(d.getDate() + days);
        document.getElementById('exp_date').value = d.toISOString().split('T')[0];
    }
</script></div></body></html>
EOF

# Прочие шаблоны
cat <<EOF > templates/channels.html
<!DOCTYPE html><html><head><meta charset="UTF-8"><style>
body { font-family: sans-serif; background: #f0f2f5; padding: 20px; }
.card { background: white; padding: 20px; border-radius: 12px; max-width: 900px; margin: auto; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
input { padding: 8px; border: 1px solid #ddd; border-radius: 6px; }
table { width: 100%; border-collapse: collapse; margin-top:20px; }
th, td { padding: 10px; border-bottom: 1px solid #eee; text-align: left; font-size: 13px; }
th { background: #e67e22; color: white; }
</style></head><body><div class="card"><h3>$L_CHANNELS</h3>
<form method="POST" style="display:flex; gap:10px;">
<input type="text" name="name" placeholder="$L_CH_NAME" required><input type="text" name="group" placeholder="$L_CH_GRP">
<input type="text" name="url" placeholder="$L_CH_URL" required style="flex-grow:1;"><button type="submit" style="padding:8px 15px; background:#2ecc71; color:white; border:none; border-radius:6px;">+</button>
</form><table><tr><th>$L_CH_NAME</th><th>$L_CH_GRP</th><th>URL</th><th>$L_ACT</th></tr>
{% for c in channels %}<tr><td>{{ c.name }}</td><td>{{ c.group }}</td><td style="color:#888; font-size:11px;">{{ c.url[:50] }}...</td>
<td><a href="/channel/edit/{{ c.id }}">📝</a> <a href="/channel/delete/{{ c.id }}" style="color:red;">X</a></td></tr>{% endfor %}
</table><br><a href="/admin" style="color:#999; text-decoration:none;">← Back</a></div></body></html>
EOF

cat <<EOF > templates/edit_ch.html
<!DOCTYPE html><html><head><meta charset="UTF-8"><style>
body { font-family: sans-serif; background: #f0f2f5; display: flex; justify-content: center; padding-top: 50px; }
.card { background: white; padding: 25px; border-radius: 12px; width: 400px; box-shadow: 0 4px 15px rgba(0,0,0,0.1); }
input { width: 100%; padding: 10px; margin: 8px 0; border: 1px solid #ddd; border-radius: 6px; box-sizing: border-box; }
</style></head><body><div class="card"><form method="POST">
<input type="text" name="name" value="{{ ch.name }}" required><input type="text" name="group" value="{{ ch.group }}">
<input type="text" name="url" value="{{ ch.url }}" required><button type="submit" style="background:#3498db; color:white; border:none; padding:12px; width:100%; border-radius:6px;">$L_SAVE</button>
</form><a href="/channels" style="display:block; text-align:center; margin-top:15px; color:#999; text-decoration:none;">Cancel</a></div></body></html>
EOF

cat <<EOF > templates/settings.html
<!DOCTYPE html><html><head><meta charset="UTF-8"><style>
body { font-family: sans-serif; background: #f0f2f5; padding: 40px; }
.card { background: white; padding: 30px; border-radius: 12px; max-width: 600px; margin: auto; box-shadow: 0 4px 10px rgba(0,0,0,0.1); }
</style></head><body><div class="card"><h2>$L_SET</h2>
<form method="POST" style="border-bottom: 1px solid #eee; padding-bottom: 20px; margin-bottom: 20px;">
<label>$L_PORT:</label><input type="number" name="port" value="{{ port }}" style="padding:8px; width:80px;">
<button type="submit" style="padding:8px 15px; background:#2ecc71; color:white; border:none; border-radius:4px; font-weight:bold;">$L_SAVE</button>
</form><div style="background:#e8f4fd; padding:20px; border-radius:10px; border:1px solid #3498db;">
<h3 style="margin-top:0; color:#2980b9;">🔐 Admin / Password</h3>
<code style="background:#222; color:#00ff00; padding:12px; display:block; border-radius:5px; font-size:13px;">sudo /opt/iptv_manager/reset.sh $L_LOG_PASS</code>
</div><br><a href="/admin" style="color:#999; text-decoration:none;">← Back</a></div></body></html>
EOF

cat <<'EOF' > templates/login.html
<html><body style="background:#1a1a1a;color:white;display:flex;justify-content:center;align-items:center;height:100vh;font-family:sans-serif;"><form method="post" style="background:#333;padding:25px;border-radius:10px;"><h2>IPTV Login</h2><input name="username" placeholder="Login" required style="display:block;margin-bottom:10px;padding:8px;"><input name="password" type="password" placeholder="Password" required style="display:block;margin-bottom:20px;padding:8px;"><button type="submit" style="width:100%;padding:10px;background:#3498db;color:white;border:none;cursor:pointer;">Login</button></form></body></html>
EOF

cat <<'EOF' > templates/settings_ok.html
<!DOCTYPE html><html><head><meta charset="UTF-8"></head><body style="font-family:sans-serif; background:#f0f2f5; padding:50px; text-align:center;"><div style="background:white; padding:30px; border-radius:12px; display:inline-block; border:1px solid #2ecc71;"><h3 style="color:#27ae60;">Port Saved!</h3><code>sudo systemctl restart iptv_manager</code><br><br><a href="/admin">← Back</a></div></body></html>
EOF

# --- CREATE RESET.SH (ИСПРАВЛЕНО ДЛЯ НОВЫХ СЕРВЕРОВ) ---
cat <<'EOF' > reset.sh
#!/bin/bash
if [ -z "$1" ] || [ -z "$2" ]; then echo "Usage: sudo ./reset.sh user pass"; exit 1; fi

cd /opt/iptv_manager

cat <<EOP > temp_reset.py
from app import db, Admin, app
from werkzeug.security import generate_password_hash
with app.app_context():
    # Принудительно создаем таблицы, чтобы не было ошибки "no such table"
    db.create_all()
    a = Admin.query.first()
    if a:
        a.username = '$1'
        a.password = generate_password_hash('$2')
    else:
        # Если админа нет (база пуста), создаем нового
        db.session.add(Admin(username='$1', password=generate_password_hash('$2')))
    db.session.commit()
EOP
/opt/iptv_manager/venv/bin/python3 temp_reset.py
rm temp_reset.py
systemctl restart iptv_manager
echo "Done! Credentials updated."
EOF
chmod +x reset.sh

# --- SERVICE ---
cat <<EOF > /etc/systemd/system/iptv_manager.service
[Unit]
Description=IPTV Manager Panel
After=network.target

[Service]
User=root
WorkingDirectory=/opt/iptv_manager
ExecStart=/opt/iptv_manager/venv/bin/python3 app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable iptv_manager
systemctl start iptv_manager

IP=$(hostname -I | awk '{print $1}')
echo "------------------------------------------------"
echo "INSTALLATION COMPLETE!"
echo "Access: http://$IP:8090/login"
echo "Default: admin / admin"
echo "------------------------------------------------"
