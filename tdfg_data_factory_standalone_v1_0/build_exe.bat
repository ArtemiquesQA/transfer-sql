@echo off
chcp 65001 > nul
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
python -m pip install pyinstaller
pyinstaller --onefile --noconsole --name TDFG_Data_Factory tdfg_data_factory.py
pause
