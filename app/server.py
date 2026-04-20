import os
from datetime import datetime
from flask import Flask, send_from_directory, render_template, abort

app = Flask(__name__)
SCANS_DIR = os.environ.get("SCANS_DIR", "/srv/scans")


def human_size(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


@app.route("/")
def index():
    try:
        entries = os.listdir(SCANS_DIR)
    except FileNotFoundError:
        entries = []

    files = []
    for fname in entries:
        fpath = os.path.join(SCANS_DIR, fname)
        if os.path.isfile(fpath):
            stat = os.stat(fpath)
            files.append(
                {
                    "name": fname,
                    "size": human_size(stat.st_size),
                    "modified": datetime.fromtimestamp(stat.st_mtime),
                }
            )

    files.sort(key=lambda x: x["modified"], reverse=True)
    latest = files[0]["name"] if files else None
    return render_template("index.html", files=files, latest=latest)


@app.route("/download/<path:filename>")
def download(filename):
    # Prevent path traversal
    safe = os.path.join(SCANS_DIR, os.path.basename(filename))
    if not os.path.isfile(safe):
        abort(404)
    return send_from_directory(SCANS_DIR, os.path.basename(filename), as_attachment=True)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=False)
