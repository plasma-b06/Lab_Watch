@app.post("/api/pc-update")
def receive_report():
    data = request.json
    # Save to database, send Telegram/email alert if "Not Usable"
    # Show live dashboard with all PCs
    return {"status": "received"}
