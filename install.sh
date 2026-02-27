#!/bin/bash

# Root check
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit
fi

echo "--- IPTV Manager Installer ---"
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

class Client(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(50))
    token = db.Column(db.String(100), unique=True)
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
            db.session.add(Client(username=request.form['username'], token=request.form['token'], playlist_file=request.form['playlist_file'], expire_date=datetime.strptime(d, '%Y-%m-%d').date()))
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
            u.username, u.token, u.playlist_file = request.form['username'], request.form['token'], request.form['playlist_file']
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
        return 'OK! <a href="/admin">Back</a>'
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
    u = Client.query.filter_by(token=request.args.get('token')).first()
    if u and u.expire_date >= datetime.now().date():
        p = os.path.join(app.config['PLAYLIST_FOLDER'], u.playlist_file)
        if os.path.exists(p):
            with open(p, 'r', encoding='utf-8') as f: return Response(f.read(), mimetype='text/plain')
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
    L_TITLE="Управление клиентами"; L_SET="Настройки"; L_BACKUP="Бэкап"; L_RESTORE="Восстановить"; L_OUT="Выход";
    L_NAME="Имя"; L_TOKEN="Токен"; L_FILE="Файл"; L_DATE="Срок"; L_ACT="Действие"; L_CREATE="Создать";
    L_UNLIM="Безлимит"; L_EDIT="Изменить"; L_DEL="Удалить"; L_SET_TITLE="Настройки панели"; L_PORT="Порт"; L_SAVE="Сохранить";
    L_CMD_TEXT="Для смены Admin / Pass введите в терминале:"; L_LOG_PASS="ЛОГИН ПАРОЛЬ"; L_CHOOSE="Выбрать файл";
    L_DATE_LANG="ru-RU"; L_PORT_OK="Порт сохранен! Выполните в терминале:";
    L_UNINSTALL="ДЛЯ УДАЛЕНИЯ ВСЕГО ПРОЕКТА:";
else
    L_TITLE="Client Management"; L_SET="Settings"; L_BACKUP="Backup"; L_RESTORE="Restore"; L_OUT="Logout";
    L_NAME="Name"; L_TOKEN="Token"; L_FILE="File"; L_DATE="Expire"; L_ACT="Action"; L_CREATE="Create";
    L_UNLIM="Unlimited"; L_EDIT="Edit"; L_DEL="Delete"; L_SET_TITLE="Panel Settings"; L_PORT="Port"; L_SAVE="Save";
    L_CMD_TEXT="To change Admin / Pass, run in terminal:"; L_LOG_PASS="USER PASS"; L_CHOOSE="Choose File";
    L_DATE_LANG="en-US"; L_PORT_OK="Port saved! Run in terminal:";
    L_UNINSTALL="TO UNINSTALL THE ENTIRE PROJECT:";
fi

# --- TEMPLATES ---
cat <<EOF > templates/admin.html
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>IPTV Panel</title>
<style>
    body { font-family: sans-serif; background: #f0f2f5; padding: 20px; }
    .card { background: white; padding: 20px; border-radius: 12px; max-width: 1050px; margin: auto; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
    .btn { padding: 8px 15px; border-radius: 6px; text-decoration: none; color: white; cursor: pointer; border: none; font-size: 13px; font-weight: bold; }
    form { background: #f8f9fa; padding: 15px; border-radius: 10px; display: flex; gap: 10px; margin: 20px 0; align-items: center; }
    input, select { padding: 10px; border: 1px solid #ddd; border-radius: 6px; }
    table { width: 100%; border-collapse: collapse; }
    th, td { padding: 12px; border-bottom: 1px solid #eee; text-align: left; }
    th { background: #4a69bd; color: white; }
    .file-input-wrapper { position: relative; overflow: hidden; display: inline-block; }
    .file-input-wrapper input[type=file] { font-size: 100px; position: absolute; left: 0; top: 0; opacity: 0; cursor: pointer; }
    .btn-file { background: #eee; color: #555; border: 1px solid #ccc; padding: 7px 10px; border-radius: 5px; font-size: 11px; }
</style>
</head><body lang="$L_DATE_LANG"><div class="card">
<div style="display:flex; justify-content:space-between; align-items:center;">
    <h2>$L_TITLE</h2>
    <div style="display:flex; gap:10px; align-items:center;">
        <a href="/settings" class="btn" style="background:#9b59b6;">$L_SET</a>
        <a href="/backup" class="btn" style="background:#27ae60;">$L_BACKUP</a>
        <form action="/restore" method="POST" enctype="multipart/form-data" style="margin:0; background:none; padding:0; border:none; display:flex; gap:5px;">
            <div class="file-input-wrapper">
                <button class="btn-file" type="button">$L_CHOOSE</button>
                <input type="file" name="backup_file" required onchange="this.previousElementSibling.innerText=this.files[0].name">
            </div>
            <button type="submit" class="btn" style="background:#f39c12;">$L_RESTORE</button>
        </form>
        <a href="/logout" style="color:red; text-decoration:none; font-weight:bold;">$L_OUT</a>
    </div>
</div>
<form method="POST">
    <input type="text" name="username" placeholder="$L_NAME" required>
    <input type="text" name="token" placeholder="$L_TOKEN" required>
    <select name="playlist_file" required>
        <option value="">-- $L_FILE --</option>
        {% for file in files %}<option value="{{ file }}">{{ file }}</option>{% endfor %}
    </select>
    <input type="date" name="expire_date" id="d_add">
    <button type="button" onclick="document.getElementById('d_add').value='2099-12-31'" style="border:none; background:none; cursor:pointer; font-size:20px;">♾️</button>
    <button type="submit" class="btn" style="background:#2ecc71;">$L_CREATE</button>
</form>
<table>
    <tr><th>$L_NAME</th><th>URL</th><th>$L_FILE</th><th>$L_DATE</th><th>$L_ACT</th></tr>
    {% for user in users %}
    <tr>
        <td>{{ user.username }}</td>
        <td><code>{{ request.host_url }}get?token={{ user.token }}</code></td>
        <td>{{ user.playlist_file }}</td>
        <td>{% if user.expire_date == unlim_val %}<span style="color:green">$L_UNLIM ♾️</span>{% else %}{{ user.expire_date }}{% endif %}</td>
        <td>
            <a href="/edit/{{ user.id }}" style="color:#3498db; margin-right:10px; text-decoration:none;">$L_EDIT</a>
            <a href="/delete/{{ user.id }}" style="color:red; text-decoration:none; font-weight:bold;" onclick="return confirm('?')">X</a>
        </td>
    </tr>
    {% endfor %}
</table>
</div></body></html>
EOF

cat <<EOF > templates/settings.html
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Settings</title>
<style>
    body { font-family: sans-serif; background: #f0f2f5; padding: 40px; }
    .card { background: white; padding: 30px; border-radius: 12px; max-width: 600px; margin: auto; box-shadow: 0 4px 10px rgba(0,0,0,0.1); }
</style>
</head><body><div class="card">
<h2>$L_SET_TITLE</h2>
<form method="POST" style="border-bottom: 1px solid #eee; padding-bottom: 20px; margin-bottom: 20px;">
    <label>$L_PORT:</label>
    <input type="number" name="port" value="{{ port }}" style="padding:8px; width:80px;">
    <button type="submit" style="padding:8px 15px; background:#2ecc71; color:white; border:none; border-radius:4px; font-weight:bold;">$L_SAVE</button>
</form>
<div style="background:#e8f4fd; padding:20px; border-radius:10px; border:1px solid #3498db;">
    <h3 style="margin-top:0; color:#2980b9;">🔐 Admin / Password</h3>
    <p style="font-size:14px;">$L_CMD_TEXT</p>
    <code style="background:#222; color:#00ff00; padding:12px; display:block; border-radius:5px; font-size:13px;">
        sudo /opt/iptv_manager/reset.sh $L_LOG_PASS
    </code>
</div>
<br><a href="/admin" style="color:#999; text-decoration:none;">← Back</a>
</div></body></html>
EOF

cat <<EOF > templates/settings_ok.html
<!DOCTYPE html><html><head><meta charset="UTF-8"></head>
<body style="font-family:sans-serif; background:#f0f2f5; padding:50px; text-align:center;">
<div style="background:white; padding:30px; border-radius:12px; display:inline-block; border:1px solid #2ecc71;">
    <h3 style="color:#27ae60;">$L_PORT_OK</h3>
    <code style="background:#222; color:#00ff00; padding:10px; display:block; margin:15px 0;">sudo systemctl restart iptv_manager</code>
    <a href="/admin" style="text-decoration:none; color:#3498db; font-weight:bold;">← OK / Back</a>
</div>
</body></html>
EOF

cat <<'EOF' > templates/edit.html
<!DOCTYPE html><html><head><meta charset="UTF-8"><style>
    body { font-family: sans-serif; background: #f0f2f5; display: flex; justify-content: center; padding-top: 40px; }
    .card { background: white; padding: 25px; border-radius: 12px; width: 360px; box-shadow: 0 4px 15px rgba(0,0,0,0.1); }
    input, select { width: 100%; padding: 10px; margin: 8px 0; border: 1px solid #ddd; border-radius: 6px; box-sizing: border-box; }
    .btn-fast { padding: 6px; font-size: 11px; cursor: pointer; background: #eee; border: 1px solid #ccc; border-radius: 4px; margin-right: 4px; }
</style></head><body><div class="card">
<form method="POST">
    <input type="text" name="username" value="{{ user.username }}" required>
    <input type="text" name="token" value="{{ user.token }}" required>
    <select name="playlist_file">
        {% for file in files %}<option value="{{ file }}" {% if file == user.playlist_file %}selected{% endif %}>{{ file }}</option>{% endfor %}
    </select>
    <input type="date" name="expire_date" id="exp_date" value="{{ user.expire_date }}" required>
    <div style="margin-bottom: 15px;">
        <button type="button" class="btn-fast" onclick="setDate(30)">+30 d</button>
        <button type="button" class="btn-fast" onclick="setDate(365)">+1 y</button>
        <button type="button" class="btn-fast" onclick="setUnlim()">♾️</button>
    </div>
    <button type="submit" style="background:#3498db; color:white; border:none; padding:12px; width:100%; border-radius:6px; cursor:pointer; font-weight:bold;">Save</button>
</form>
<a href="/admin" style="display:block; text-align:center; margin-top:15px; color:#999; text-decoration:none;">Cancel</a>
</div>
<script>
    function setDate(d_plus) { let d=new Date(); d.setDate(d.getDate()+d_plus); document.getElementById('exp_date').value=d.toISOString().split('T')[0]; }
    function setUnlim() { document.getElementById('exp_date').value='2099-12-31'; }
</script></body></html>
EOF

cat <<'EOF' > templates/login.html
<html><body style="background:#1a1a1a;color:white;display:flex;justify-content:center;align-items:center;height:100vh;font-family:sans-serif;"><form method="post" style="background:#333;padding:25px;border-radius:10px;"><h2>IPTV Login</h2><input name="username" placeholder="Login" required style="display:block;margin-bottom:10px;padding:8px;"><input name="password" type="password" placeholder="Password" required style="display:block;margin-bottom:20px;padding:8px;"><button type="submit" style="width:100%;padding:10px;background:#3498db;color:white;border:none;cursor:pointer;">Login</button></form></body></html>
EOF

# --- CREATE RESET.SH ---
cat <<'EOF' > reset.sh
#!/bin/bash
if [ -z "$1" ] || [ -z "$2" ]; then echo "Usage: sudo ./reset.sh user pass"; exit 1; fi
cat <<EOP > temp_reset.py
from app import db, Admin, app
from werkzeug.security import generate_password_hash
with app.app_context():
    a = Admin.query.first()
    if a:
        a.username = '$1'
        a.password = generate_password_hash('$2')
        db.session.commit()
EOP
/opt/iptv_manager/venv/bin/python3 temp_reset.py
rm temp_reset.py
systemctl restart iptv_manager
echo "Done! Credentials updated and service restarted."
EOF
chmod +x reset.sh

# --- CREATE SERVICE ---
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
echo "Access your panel at: http://$IP:8090/login"
echo "Default credentials: admin / admin"
echo ""
echo "$L_UNINSTALL"
echo "sudo systemctl stop iptv_manager && sudo systemctl disable iptv_manager && sudo rm /etc/systemd/system/iptv_manager.service && sudo rm -rf /opt/iptv_manager && sudo systemctl daemon-reload"
echo "------------------------------------------------"
