#!/bin/bash

# Скрипт установки IPTV Manager
# Поддерживает Ubuntu 20.04 и 24.04

set -e

echo "--- Установка системных зависимостей ---"
sudo apt update
sudo apt install -y python3 python3-pip python3-venv sqlite3

# Настройка путей
INSTALL_DIR="/opt/iptv_manager"
PLAYLIST_DIR="$INSTALL_DIR/playlists"
TEMPLATE_DIR="$INSTALL_DIR/templates"

echo "--- Создание структуры папок ---"
sudo mkdir -p $PLAYLIST_DIR
sudo mkdir -p $TEMPLATE_DIR

# Запрос порта у пользователя
read -p "Введите порт для работы панели (по умолчанию 5000): " USER_PORT
USER_PORT=${USER_PORT:-5000}

echo "--- Создание виртуального окружения и установка Flask ---"
sudo python3 -m venv $INSTALL_DIR/venv
sudo $INSTALL_DIR/venv/bin/pip install flask flask-sqlalchemy flask-login

echo "--- Запись файлов проекта ---"

# 1. Запись app.py
cat <<EOF | sudo tee $INSTALL_DIR/app.py > /dev/null
# -*- coding: utf-8 -*-
from flask import Flask, request, render_template, redirect, url_for, Response, send_file
from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager, UserMixin, login_user, login_required, logout_user, current_user
from werkzeug.security import check_password_hash, generate_password_hash
from datetime import datetime
import os, shutil

app = Flask(__name__)
app.config['SECRET_KEY'] = 'gerkules-ultimate-fix'
app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///$INSTALL_DIR/iptv.db'
app.config['PLAYLIST_FOLDER'] = '$PLAYLIST_DIR'
app.config['DB_PATH'] = '$INSTALL_DIR/iptv.db'

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
    auto_delete = db.Column(db.Boolean, default=False)

@login_manager.user_loader
def load_user(user_id):
    return Admin.query.get(int(user_id))

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        user = Admin.query.filter_by(username=request.form.get('username')).first()
        if user and check_password_hash(user.password, request.form.get('password')):
            login_user(user)
            return redirect(url_for('admin'))
        return "Ошибка входа", 401
    
    return '''
    <!DOCTYPE html>
    <html>
    <head>
        <meta charset="UTF-8">
        <title>IPTV Login</title>
        <style>
            body { font-family: sans-serif; background: #f0f2f5; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
            .login-card { background: white; padding: 30px; border-radius: 12px; box-shadow: 0 8px 20px rgba(0,0,0,0.1); width: 100%; max-width: 350px; text-align: center; }
            h2 { color: #2c3e50; margin-bottom: 25px; }
            input { width: 100%; padding: 12px; margin-bottom: 15px; border: 1px solid #ddd; border-radius: 6px; box-sizing: border-box; font-size: 14px; }
            button { width: 100%; padding: 12px; background: #3498db; color: white; border: none; border-radius: 6px; font-size: 16px; font-weight: bold; cursor: pointer; transition: background 0.3s; }
            button:hover { background: #2980b9; }
            .hint { font-size: 12px; color: #7f8c8d; margin-top: 15px; }
        </style>
    </head>
    <body>
        <div class="login-card">
            <h2>Вход в панель</h2>
            <form method="POST">
                <input type="text" name="username" placeholder="Логин" required>
                <input type="password" name="password" placeholder="Пароль" required>
                <button type="submit">Войти</button>
            </form>
            <div class="hint">Логин: admin / Пароль: admin</div>
        </div>
    </body>
    </html>
    '''

@app.route('/admin', methods=['GET', 'POST'])
@login_required
def admin():
    if request.method == 'POST':
        new_client = Client(
            username=request.form.get('username'),
            token=request.form.get('token'),
            playlist_file=request.form.get('playlist_file'),
            expire_date=datetime.strptime(request.form.get('expire_date'), '%Y-%m-%d').date(),
            auto_delete='auto_delete' in request.form
        )
        db.session.add(new_client)
        db.session.commit()
        return redirect(url_for('admin'))
    
    users = Client.query.all()
    files = [f for f in os.listdir(app.config['PLAYLIST_FOLDER']) if f.endswith(('.m3u', '.m3u8'))]
    return render_template('admin.html', users=users, files=files)

@app.route('/edit/<int:id>', methods=['GET', 'POST'])
@login_required
def edit_user(id):
    user = Client.query.get_or_404(id)
    if request.method == 'POST':
        user.username = request.form.get('username')
        user.token = request.form.get('token')
        user.playlist_file = request.form.get('playlist_file')
        user.expire_date = datetime.strptime(request.form.get('expire_date'), '%Y-%m-%d').date()
        user.auto_delete = 'auto_delete' in request.form
        db.session.commit()
        return redirect(url_for('admin'))
    files = [f for f in os.listdir(app.config['PLAYLIST_FOLDER']) if f.endswith(('.m3u', '.m3u8'))]
    return render_template('edit.html', user=user, files=files)

@app.route('/settings', methods=['GET', 'POST'])
@login_required
def settings():
    port_setting = Settings.query.filter_by(key='port').first()
    current_port = port_setting.value if port_setting else "5000"
    if request.method == 'POST':
        admin_user = Admin.query.get(current_user.id)
        if request.form.get('username'): admin_user.username = request.form.get('username')
        if request.form.get('password'): admin_user.password = generate_password_hash(request.form.get('password'))
        new_port = request.form.get('port', '5000')
        if not port_setting:
            db.session.add(Settings(key='port', value=new_port))
        else:
            port_setting.value = new_port
        db.session.commit()
        return f'Настройки сохранены! Порт: {new_port}. Перезапустите сервис (systemctl restart iptv_manager). <br><a href="/admin">Назад</a>'
    
    return f'''
    <!DOCTYPE html>
    <html>
    <head>
        <meta charset="UTF-8">
        <style>
            body {{ font-family: sans-serif; background: #f4f7f6; display: flex; justify-content: center; padding-top: 50px; }}
            .card {{ background: white; padding: 30px; border-radius: 12px; box-shadow: 0 4px 15px rgba(0,0,0,0.1); width: 400px; }}
            h3 {{ color: #2c3e50; text-align: center; }}
            input {{ width: 100%; padding: 10px; margin: 10px 0; border: 1px solid #ddd; border-radius: 6px; box-sizing: border-box; }}
            label {{ font-size: 13px; color: #666; }}
            button {{ width: 100%; padding: 12px; background: #2ecc71; color: white; border: none; border-radius: 6px; cursor: pointer; font-weight: bold; margin-top: 10px; }}
        </style>
    </head>
    <body>
        <div class="card">
            <h3>⚙️ Настройки сервера</h3>
            <form method="POST">
                <label>Логин администратора</label>
                <input name="username" value="{current_user.username}">
                <label>Новый пароль (пусто = не менять)</label>
                <input type="password" name="password" placeholder="********">
                <label>Порт сервера</label>
                <input type="number" name="port" value="{current_port}">
                <button type="submit">Сохранить изменения</button>
            </form>
            <hr style="margin: 25px 0; border: 0; border-top: 1px solid #eee;">
            <a href="/admin" style="display: block; text-align: center; color: #95a5a6; text-decoration: none;">← Вернуться</a>
        </div>
    </body>
    </html>
    '''

@app.route('/backup')
@login_required
def backup():
    return send_file(app.config['DB_PATH'], as_attachment=True, download_name="iptv_backup.db")

@app.route('/restore', methods=['POST'])
@login_required
def restore():
    file = request.files.get('backup_file')
    if file and file.filename.endswith('.db'):
        temp_path = app.config['DB_PATH'] + '.new'
        file.save(temp_path)
        shutil.move(temp_path, app.config['DB_PATH'])
        return 'База восстановлена! <a href="/admin">Вернуться</a>'
    return "Ошибка файла", 400

@app.route('/delete/<int:id>')
@login_required
def delete_user(id):
    user = Client.query.get_or_404(id)
    db.session.delete(user)
    db.session.commit()
    return redirect(url_for('admin'))

@app.route('/get')
def get_playlist():
    token = request.args.get('token')
    user = Client.query.filter_by(token=token).first()
    if user and user.expire_date >= datetime.now().date():
        file_path = os.path.join(app.config['PLAYLIST_FOLDER'], user.playlist_file)
        if os.path.exists(file_path):
            with open(file_path, 'r', encoding='utf-8') as f:
                return Response(f.read(), mimetype='text/plain')
    return "Доступ запрещен", 403

@app.route('/logout')
def logout():
    logout_user()
    return redirect(url_for('login'))

if __name__ == '__main__':
    with app.app_context():
        db.create_all()
        if not Admin.query.first():
            db.session.add(Admin(username='admin', password=generate_password_hash('admin')))
            db.session.commit()
        p = Settings.query.filter_by(key='port').first()
        if not p:
            db.session.add(Settings(key='port', value=str($USER_PORT)))
            db.session.commit()
            run_port = $USER_PORT
        else:
            run_port = int(p.value)
    app.run(host='0.0.0.0', port=run_port)
EOF

# 2. Запись admin.html
cat <<EOF | sudo tee $TEMPLATE_DIR/admin.html > /dev/null
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <title>IPTV Manager</title>
    <style>
        body { font-family: sans-serif; background: #f4f7f6; padding: 20px; color: #333; }
        .container { max-width: 1100px; margin: auto; background: white; padding: 25px; border-radius: 12px; box-shadow: 0 4px 15px rgba(0,0,0,0.1); }
        .top-bar { display: flex; justify-content: space-between; align-items: center; margin-bottom: 25px; border-bottom: 1px solid #eee; padding-bottom: 15px; }
        .btn { padding: 9px 16px; border-radius: 6px; text-decoration: none; color: white; font-size: 13px; font-weight: bold; cursor: pointer; border: none; transition: 0.2s; }
        .btn:hover { opacity: 0.85; }
        .btn-settings { background: #9b59b6; }
        .btn-backup { background: #27ae60; }
        .btn-restore { background: #f39c12; }
        .btn-logout { background: #7f8c8d; }
        .btn-add { background: #2ecc71; }
        form.add-form { background: #f8f9fa; padding: 18px; border-radius: 10px; display: flex; gap: 10px; margin-bottom: 25px; align-items: center; border: 1px solid #eef0f2; }
        form.add-form input, select { padding: 10px; border: 1px solid #ddd; border-radius: 6px; flex: 1; }
        table { width: 100%; border-collapse: collapse; }
        th, td { padding: 14px; border-bottom: 1px solid #f0f0f0; text-align: left; }
        th { background: #4a69bd; color: white; }
        code { background: #ebedef; padding: 4px 8px; border-radius: 4px; font-size: 12px; }
    </style>
</head>
<body>
<div class="container">
    <div class="top-bar">
        <div style="display:flex; gap:12px;">
            <a href="/settings" class="btn btn-settings">⚙️ Настройки</a>
            <a href="/backup" class="btn btn-backup">📥 Бэкап</a>
            <form action="/restore" method="POST" enctype="multipart/form-data" style="display:flex; gap:8px;">
                <input type="file" name="backup_file" accept=".db" required style="font-size:11px; width:140px;">
                <button type="submit" class="btn btn-restore">Восстановить</button>
            </form>
        </div>
        <a href="/logout" class="btn btn-logout">Выйти</a>
    </div>

    <h2>Управление клиентами</h2>

    <form class="add-form" method="POST">
        <input type="text" name="username" placeholder="Имя клиента" required>
        <input type="text" name="token" placeholder="Токен" required>
        <select name="playlist_file" required>
            <option value="">-- Файл --</option>
            {% for file in files %}<option value="{{ file }}">{{ file }}</option>{% endfor %}
        </select>
        <input type="date" name="expire_date" required>
        <button type="submit" class="btn btn-add">Добавить</button>
    </form>

    <table>
        <tr>
            <th>Имя</th>
            <th>Ссылка</th>
            <th>Файл</th>
            <th>До даты</th>
            <th>Действие</th>
        </tr>
        {% for user in users %}
        <tr>
            <td><strong>{{ user.username }}</strong></td>
            <td><code>{{ request.host_url }}get?token={{ user.token }}</code></td>
            <td>{{ user.playlist_file }}</td>
            <td>{{ user.expire_date.strftime('%d.%m.%Y') }}</td>
            <td>
                <a href="/edit/{{ user.id }}" style="color:#3498db; margin-right:10px;">Изменить</a>
                <a href="/delete/{{ user.id }}" style="color:#e74c3c;" onclick="return confirm('Удалить?')">X</a>
            </td>
        </tr>
        {% endfor %}
    </table>
</div>
</body>
</html>
EOF

# 3. Запись edit.html
cat <<EOF | sudo tee $TEMPLATE_DIR/edit.html > /dev/null
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Edit Client</title>
    <style>
        body { font-family: sans-serif; background: #f4f7f6; display: flex; justify-content: center; padding-top: 50px; }
        .card { background: white; padding: 30px; border-radius: 12px; box-shadow: 0 4px 15px rgba(0,0,0,0.1); width: 380px; }
        h3 { color: #2c3e50; text-align: center; margin-bottom: 20px; }
        input, select { width: 100%; padding: 12px; margin: 10px 0; border: 1px solid #ddd; border-radius: 6px; box-sizing: border-box; }
        button { width: 100%; padding: 12px; background: #3498db; color: white; border: none; border-radius: 6px; cursor: pointer; font-weight: bold; margin-top: 15px; }
    </style>
</head>
<body>
<div class="card">
    <h3>Редактировать клиента</h3>
    <form method="POST">
        <input type="text" name="username" value="{{ user.username }}" required>
        <input type="text" name="token" value="{{ user.token }}" required>
        <select name="playlist_file">
            {% for file in files %}<option value="{{ file }}" {% if file == user.playlist_file %}selected{% endif %}>{{ file }}</option>{% endfor %}
        </select>
        <input type="date" name="expire_date" value="{{ user.expire_date }}" required>
        <button type="submit">Сохранить изменения</button>
    </form>
    <a href="/admin" style="display: block; text-align: center; color: #95a5a6; text-decoration: none; margin-top: 15px;">Отмена</a>
</div>
</body>
</html>
EOF

echo "--- Настройка прав доступа ---"
sudo chown -R $USER:$USER $INSTALL_DIR

echo "--- Создание службы systemd ---"
cat <<EOF | sudo tee /etc/systemd/system/iptv_manager.service > /dev/null
[Unit]
Description=IPTV Manager Panel
After=network.target

[Service]
User=$USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo "--- Запуск сервиса ---"
sudo systemctl daemon-reload
sudo systemctl enable iptv_manager
sudo systemctl start iptv_manager

echo "------------------------------------------------"
echo "Установка завершена!"
echo "Панель доступна по адресу: http://$(hostname -I | awk '{print $1}'):$USER_PORT"
echo "Логин: admin"
echo "Пароль: admin"
echo "Файлы плейлистов (.m3u) кладите в: $PLAYLIST_DIR"
echo "------------------------------------------------"