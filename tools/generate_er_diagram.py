"""
Generates diagrams/ER_Diagram.svg and diagrams/ER_Diagram.html (Crow's Foot
notation) for the Construction Equipment & Machinery Rental database.
PNG / PDF are produced from the HTML with headless Chrome (see README in
diagrams/). Developer tool only - not needed to run the database.

Usage (project root):  python3 tools/generate_er_diagram.py
"""
from pathlib import Path
from html import escape

ROW_H = 19
HEAD_H = 30
BOX_W = 330
PAD = 8

# (column, type, tags)  tags: PK, FK, UQ, NN-less shown as 'NULL'
TABLES = {
    "equipment_categories": [("category_id", "INT", "PK"), ("category_name", "VARCHAR(60)", "UQ"),
                             ("description", "VARCHAR(255) NULL", "")],
    "equipment_models": [("model_id", "INT", "PK"), ("category_id", "INT", "FK"), ("manufacturer", "VARCHAR(60)", "UQ1"),
                         ("model_name", "VARCHAR(60)", "UQ1"), ("capacity_spec", "VARCHAR(80) NULL", ""),
                         ("engine_power_hp", "SMALLINT NULL", ""), ("fuel_type", "ENUM", ""),
                         ("daily_rate", "DECIMAL(10,2)", ""), ("deposit_per_unit", "DECIMAL(10,2)", ""),
                         ("service_interval_rental_days", "SMALLINT", "")],
    "depots": [("depot_id", "INT", "PK"), ("depot_name", "VARCHAR(60)", "UQ"), ("city", "VARCHAR(60)", ""),
               ("state", "VARCHAR(60)", ""), ("phone", "VARCHAR(13)", "")],
    "equipment_units": [("equipment_id", "INT", "PK"), ("model_id", "INT", "FK"), ("depot_id", "INT", "FK"),
                        ("asset_tag", "VARCHAR(20)", "UQ"), ("serial_number", "VARCHAR(40)", "UQ"),
                        ("manufacture_year", "SMALLINT", ""), ("purchase_date", "DATE", ""),
                        ("purchase_cost", "DECIMAL(12,2)", ""), ("condition_rating", "ENUM", ""),
                        ("lifecycle_status", "ENUM(ACTIVE,RETIRED)", ""), ("retired_date", "DATE NULL", "")],
    "maintenance_records": [("maintenance_id", "INT", "PK"), ("equipment_id", "INT", "FK"),
                            ("technician_staff_id", "INT NULL", "FK"), ("related_return_id", "INT NULL", "FK,UQ"),
                            ("maintenance_type", "ENUM", ""), ("maintenance_status", "ENUM", ""),
                            ("scheduled_start", "DATE", ""), ("scheduled_end", "DATE", ""),
                            ("actual_start", "DATE NULL", ""), ("actual_end", "DATE NULL", ""),
                            ("maintenance_cost", "DECIMAL(10,2)", ""), ("description", "VARCHAR(255)", "")],
    "booking_items": [("booking_item_id", "INT", "PK"), ("booking_id", "INT", "FK,UQ1"),
                      ("equipment_id", "INT", "FK,UQ1"), ("agreed_daily_rate", "DECIMAL(10,2)", "")],
    "equipment_returns": [("return_id", "INT", "PK"), ("booking_item_id", "INT", "FK,UQ"),
                          ("return_date", "DATE", ""), ("received_by_staff_id", "INT", "FK"),
                          ("return_condition", "ENUM", ""), ("late_charge", "DECIMAL(12,2)", ""),
                          ("damage_charge", "DECIMAL(12,2)", ""), ("damage_description", "VARCHAR(255) NULL", ""),
                          ("return_notes", "VARCHAR(255) NULL", "")],
    "staff": [("staff_id", "INT", "PK"), ("full_name", "VARCHAR(100)", ""), ("staff_role", "ENUM", ""),
              ("phone", "VARCHAR(13)", "UQ"), ("email", "VARCHAR(100)", "UQ"), ("hire_date", "DATE", ""),
              ("manager_id", "INT NULL", "FK"), ("is_active", "BOOLEAN", "")],
    "bookings": [("booking_id", "INT", "PK"), ("customer_id", "INT", "FK"), ("created_by_staff_id", "INT", "FK"),
                 ("booking_date", "DATE", ""), ("start_date", "DATE", ""), ("expected_return_date", "DATE", ""),
                 ("booking_status", "ENUM", ""), ("site_address", "VARCHAR(200)", ""),
                 ("cancelled_date", "DATE NULL", ""), ("cancellation_reason", "VARCHAR(200) NULL", "")],
    "customers": [("customer_id", "INT", "PK"), ("customer_type", "ENUM", ""), ("full_name", "VARCHAR(100)", ""),
                  ("organisation_name", "VARCHAR(150) NULL", ""), ("phone", "VARCHAR(13)", "UQ"),
                  ("email", "VARCHAR(100) NULL", "UQ"), ("address_line", "VARCHAR(200)", ""),
                  ("city", "VARCHAR(60)", ""), ("state", "VARCHAR(60)", ""), ("pincode", "CHAR(6)", ""),
                  ("registration_date", "DATE", ""), ("is_active", "BOOLEAN", "")],
    "security_deposits": [("deposit_id", "INT", "PK"), ("booking_id", "INT", "FK,UQ"),
                          ("required_amount", "DECIMAL(12,2)", ""), ("collected_amount", "DECIMAL(12,2)", ""),
                          ("collected_date", "DATE NULL", ""), ("refunded_amount", "DECIMAL(12,2)", ""),
                          ("retained_amount", "DECIMAL(12,2)", ""), ("settled_date", "DATE NULL", ""),
                          ("retention_reason", "VARCHAR(200) NULL", ""), ("deposit_status", "ENUM", "")],
    "payments": [("payment_id", "INT", "PK"), ("booking_id", "INT", "FK"), ("amount", "DECIMAL(12,2)", ""),
                 ("payment_date", "DATE", ""), ("payment_method", "ENUM", ""), ("payment_type", "ENUM", ""),
                 ("payment_status", "ENUM", ""), ("reference_no", "VARCHAR(40) NULL", "UQ")],
    "booking_status_log": [("log_id", "INT", "PK"), ("booking_id", "INT", "FK"), ("old_status", "VARCHAR(20) NULL", ""),
                           ("new_status", "VARCHAR(20)", ""), ("changed_at", "DATETIME", ""),
                           ("changed_by", "VARCHAR(100)", "")],
    "system_settings": [("settings_id", "TINYINT", "PK"), ("business_date", "DATE NULL", ""),
                        ("late_fee_multiplier", "DECIMAL(4,2)", ""), ("max_rental_days", "SMALLINT", "")],
}

# group colours (header fill) - equipment / rental / money / people / config
GROUP = {
    "equipment_categories": "eq", "equipment_models": "eq", "equipment_units": "eq", "depots": "eq",
    "maintenance_records": "eq",
    "bookings": "rent", "booking_items": "rent", "equipment_returns": "rent", "booking_status_log": "rent",
    "security_deposits": "money", "payments": "money",
    "customers": "people", "staff": "people",
    "system_settings": "cfg",
}
FILL = {"eq": "#1f5f8b", "rent": "#2e7d4f", "money": "#9a6b00", "people": "#6a3d9a", "cfg": "#555555"}

X = [30, 470, 910, 1350, 1790]
POS = {
    "equipment_categories": (X[0], 30),
    "equipment_models": (X[0], 190),
    "depots": (X[0], 520),
    "system_settings": (X[0], 760),
    "equipment_units": (X[1], 30),
    "maintenance_records": (X[1], 420),
    "booking_items": (X[2], 30),
    "equipment_returns": (X[2], 230),
    "staff": (X[2], 560),
    "bookings": (X[3], 30),
    "customers": (X[3], 330),
    "security_deposits": (X[4], 30),
    "payments": (X[4], 290),
    "booking_status_log": (X[4], 520),
}


def box(name):
    x, y = POS[name]
    h = HEAD_H + ROW_H * len(TABLES[name]) + PAD
    return x, y, BOX_W, h


def row_y(name, col):
    x, y, w, h = box(name)
    for i, c in enumerate(TABLES[name]):
        if c[0] == col:
            return y + HEAD_H + ROW_H * i + ROW_H / 2 + 3
    raise KeyError(col)


def left(name, col):
    x, y, w, h = box(name)
    return (x, row_y(name, col))


def right(name, col):
    x, y, w, h = box(name)
    return (x + w, row_y(name, col))


def top(name, frac=0.5):
    x, y, w, h = box(name)
    return (x + w * frac, y)


def bottom(name, frac=0.5):
    x, y, w, h = box(name)
    return (x + w * frac, y + h)


# Each relationship: (points..., parent_marker, child_marker, label, label_pos)
# Path is drawn from the PARENT ("one") end to the CHILD ("many") end.
def rels():
    R = []
    # categories || ---- o< models  (vertical)
    a = bottom("equipment_categories", 0.3); b = (a[0], box("equipment_models")[1])
    R.append(([a, b], "one", "zero_many", "classifies", (a[0] + 8, (a[1] + b[1]) / 2)))
    # models || ---- o< units
    a = right("equipment_models", "model_id"); b = left("equipment_units", "model_id")
    mx = a[0] + 28
    R.append(([a, (mx, a[1]), (mx, b[1]), b], "one", "zero_many", "is type of", (mx + 5, (a[1] + b[1]) / 2 + 50)))
    # depots || ---- o< units
    a = right("depots", "depot_id"); b = left("equipment_units", "depot_id")
    mx = a[0] + 72
    R.append(([a, (mx, a[1]), (mx, b[1]), b], "one", "zero_many", "parks", (a[0] + 26, a[1] - 8)))
    # units || ---- o< booking_items
    a = right("equipment_units", "equipment_id"); b = left("booking_items", "equipment_id")
    mx = (a[0] + b[0]) / 2
    R.append(([a, (mx, a[1]), (mx, b[1]), b], "one", "zero_many", "rented as", (mx - 30, a[1] - 8)))
    # bookings || ---- |< booking_items
    a = left("bookings", "booking_id"); b = right("booking_items", "booking_id")
    mx = (a[0] + b[0]) / 2
    R.append(([a, (mx, a[1]), (mx, b[1]), b], "one", "one_many", "contains", (mx - 25, a[1] - 8)))
    # units || ---- o< maintenance (vertical down)
    a = bottom("equipment_units", 0.5); b = (a[0], box("maintenance_records")[1])
    R.append(([a, b], "one", "zero_many", "undergoes", (a[0] + 8, (a[1] + b[1]) / 2)))
    # booking_items || ---- o| returns (vertical)
    a = bottom("booking_items", 0.4); b = (a[0], box("equipment_returns")[1])
    R.append(([a, b], "one", "zero_one", "returned via", (a[0] + 8, (a[1] + b[1]) / 2 + 4)))
    # returns o| ---- o| maintenance (related_return_id)
    a = left("equipment_returns", "return_id"); b = right("maintenance_records", "related_return_id")
    mx = (a[0] + b[0]) / 2
    R.append(([a, (mx, a[1]), (mx, b[1]), b], "zero_one", "zero_one", "repairs", (mx + 4, a[1] - 6)))
    # staff || ---- o< returns (received_by)  vertical up
    a = top("staff", 0.6); b = (a[0], box("equipment_returns")[1] + box("equipment_returns")[3])
    R.append(([a, b], "one", "zero_many", "receives", (a[0] + 8, (a[1] + b[1]) / 2)))
    # staff o| ---- o< maintenance (technician)
    a = left("staff", "full_name"); b = right("maintenance_records", "technician_staff_id")
    mx = (a[0] + b[0]) / 2 - 30
    R.append(([a, (mx, a[1]), (mx, b[1]), b], "zero_one", "zero_many", "services", (mx + 4, a[1] - 6)))
    # staff || ---- o< bookings (created_by)
    a = right("staff", "staff_role"); b = left("bookings", "created_by_staff_id")
    mx = b[0] - 30
    R.append(([a, (mx, a[1]), (mx, b[1]), b], "one", "zero_many", "creates", (mx - 46, (a[1] + b[1]) / 2)))
    # staff self: manager
    x, y, w, h = box("staff")
    a = right("staff", "manager_id"); b = right("staff", "staff_id")
    R.append(([a, (x + w + 60, a[1]), (x + w + 60, b[1]), b], "zero_one", "zero_many_rev", "manages", (x + w + 6, a[1] + 15)))
    # customers || ---- o< bookings (vertical up)
    a = top("customers", 0.5); b = (a[0], box("bookings")[1] + box("bookings")[3])
    R.append(([a, b], "one", "zero_many", "places", (a[0] + 8, (a[1] + b[1]) / 2)))
    # bookings || ---- o| deposits
    a = right("bookings", "booking_id"); b = left("security_deposits", "booking_id")
    mx = (a[0] + b[0]) / 2
    R.append(([a, (mx, a[1]), (mx, b[1]), b], "one", "zero_one", "secured by", (mx - 30, a[1] - 8)))
    # bookings || ---- o< payments
    a = right("bookings", "customer_id"); b = left("payments", "booking_id")
    mx = (a[0] + b[0]) / 2 - 18
    R.append(([a, (mx, a[1]), (mx, b[1]), b], "one", "zero_many", "paid by", (mx + 6, b[1] - 8)))
    # bookings || ---- |< status log
    a = right("bookings", "booking_status"); b = left("booking_status_log", "booking_id")
    mx = (a[0] + b[0]) / 2 - 36
    R.append(([a, (mx, a[1]), (mx, b[1]), b], "one", "one_many", "audited in", (mx + 6, b[1] - 8)))
    return R


MARKERS = """
<defs>
  <!-- markers are drawn at the END of a path that enters an entity; x axis = path direction -->
  <marker id="one" viewBox="-20 -10 22 20" refX="0" refY="0" markerWidth="22" markerHeight="20" orient="auto-start-reverse" markerUnits="userSpaceOnUse">
    <path d="M -10 -7 L -10 7 M -15 -7 L -15 7" stroke="#222" stroke-width="1.6" fill="none"/>
  </marker>
  <marker id="zero_one" viewBox="-26 -10 28 20" refX="0" refY="0" markerWidth="28" markerHeight="20" orient="auto-start-reverse" markerUnits="userSpaceOnUse">
    <path d="M -8 -7 L -8 7" stroke="#222" stroke-width="1.6" fill="none"/>
    <circle cx="-17" cy="0" r="4.5" stroke="#222" stroke-width="1.5" fill="#fff"/>
  </marker>
  <marker id="one_many" viewBox="-24 -10 26 20" refX="0" refY="0" markerWidth="26" markerHeight="20" orient="auto-start-reverse" markerUnits="userSpaceOnUse">
    <path d="M 0 -8 L -12 0 L 0 8 M -12 0 L 0 0 M -16 -7 L -16 7" stroke="#222" stroke-width="1.6" fill="none"/>
  </marker>
  <marker id="zero_many" viewBox="-28 -10 30 20" refX="0" refY="0" markerWidth="30" markerHeight="20" orient="auto-start-reverse" markerUnits="userSpaceOnUse">
    <path d="M 0 -8 L -12 0 L 0 8 M -12 0 L 0 0" stroke="#222" stroke-width="1.6" fill="none"/>
    <circle cx="-18" cy="0" r="4.5" stroke="#222" stroke-width="1.5" fill="#fff"/>
  </marker>
</defs>
"""


def svg():
    W, H = 2160, 1040
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
           f'font-family="Helvetica, Arial, sans-serif">', MARKERS,
           f'<rect x="0" y="0" width="{W}" height="{H}" fill="#ffffff"/>']
    # relationships first (under boxes)
    for pts, pm, cm, label, lp in rels():
        d = "M " + " L ".join(f"{p[0]:.1f} {p[1]:.1f}" for p in pts)
        start = {"one": "one", "zero_one": "zero_one"}[pm]
        end = "zero_many" if cm == "zero_many_rev" else cm
        out.append(f'<path d="{d}" stroke="#333" stroke-width="1.4" fill="none" '
                   f'marker-start="url(#{start})" marker-end="url(#{end})"/>')
        out.append(f'<text x="{lp[0]:.1f}" y="{lp[1]:.1f}" font-size="11.5" font-style="italic" fill="#444">{escape(label)}</text>')
    # entities
    for name, cols in TABLES.items():
        x, y, w, h = box(name)
        col = FILL[GROUP[name]]
        out.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="4" fill="#fff" stroke="{col}" stroke-width="1.6"/>')
        out.append(f'<path d="M {x} {y + HEAD_H} L {x} {y + 4} Q {x} {y} {x + 4} {y} L {x + w - 4} {y} Q {x + w} {y} {x + w} {y + 4} L {x + w} {y + HEAD_H} Z" fill="{col}"/>')
        out.append(f'<text x="{x + 10}" y="{y + 20}" font-size="15" font-weight="bold" fill="#fff">{name}</text>')
        for i, (c, t, tags) in enumerate(cols):
            ry = y + HEAD_H + ROW_H * i + ROW_H - 4
            if i % 2 == 1:
                out.append(f'<rect x="{x + 1}" y="{y + HEAD_H + ROW_H * i}" width="{w - 2}" height="{ROW_H}" fill="#f4f6f8"/>')
            tag_txt = tags.replace("UQ1", "UQ*")
            weight = "bold" if "PK" in tags else "normal"
            deco = ' text-decoration="underline"' if "PK" in tags else ""
            tcol = "#b00020" if "PK" in tags else ("#0b57d0" if "FK" in tags else "#555")
            out.append(f'<text x="{x + 8}" y="{ry}" font-size="11" font-weight="bold" fill="{tcol}">{escape(tag_txt)}</text>')
            out.append(f'<text x="{x + 62}" y="{ry}" font-size="12.5" font-weight="{weight}"{deco} fill="#111">{escape(c)}</text>')
            out.append(f'<text x="{x + w - 8}" y="{ry}" font-size="11" fill="#666" text-anchor="end">{escape(t)}</text>')
    # title + legend
    lx, ly = 470, 900
    out.append(f'<text x="{lx}" y="{ly}" font-size="22" font-weight="bold" fill="#111">Construction Equipment &amp; Machinery Rental - ER Diagram (Crow\'s Foot)</text>')
    out.append(f'<text x="{lx}" y="{ly + 24}" font-size="13" fill="#444">Database: construction_rental_db  |  14 tables  |  16 foreign keys  |  MySQL 8.0+ (InnoDB)  |  Arshpreet Kaur, Manan Kochhar, Atharv Bains - Chitkara University</text>')
    legend = [("one", "exactly one (mandatory)"), ("zero_one", "zero or one (optional)"),
              ("one_many", "one or many"), ("zero_many", "zero or many")]
    for i, (m, txt) in enumerate(legend):
        bx = lx + i * 300
        out.append(f'<path d="M {bx} {ly + 56} L {bx + 60} {ly + 56}" stroke="#333" stroke-width="1.4" marker-end="url(#{m})"/>')
        out.append(f'<text x="{bx + 72}" y="{ly + 60}" font-size="13" fill="#222">{txt}</text>')
    out.append(f'<text x="{lx}" y="{ly + 92}" font-size="12.5" fill="#444">PK = primary key, FK = foreign key, UQ = unique, UQ* = part of a composite unique key.  '
               f'Header colours: blue = equipment, green = rental, gold = money, purple = people, grey = configuration.</text>')
    out.append(f'<text x="{lx}" y="{ly + 112}" font-size="12.5" fill="#444">booking_items resolves the M:N relationship BOOKING - EQUIPMENT_UNIT. '
               f'system_settings is a stand-alone single-row configuration table (business date, late-fee multiplier).</text>')
    out.append("</svg>")
    return "\n".join(out)


def main():
    root = Path(__file__).resolve().parent.parent
    d = root / "diagrams"
    d.mkdir(exist_ok=True)
    s = svg()
    (d / "ER_Diagram.svg").write_text(s, encoding="utf-8")
    html = ("<!doctype html><html><head><meta charset='utf-8'><title>ER Diagram</title>"
            "<style>@page { size: 2160px 1040px; margin: 0 } html,body{margin:0;padding:0;background:#fff;overflow:hidden} svg{display:block}</style>"
            "</head><body>" + s + "</body></html>")
    (d / "ER_Diagram.html").write_text(html, encoding="utf-8")
    print("wrote", d / "ER_Diagram.svg", "and", d / "ER_Diagram.html")


if __name__ == "__main__":
    main()
