import json, pathlib
def load_settings(path='config/settings.json'):
    p=pathlib.Path(path); return json.load(p.open())
