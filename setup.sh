#!/bin/bash
# Complete Restaurant Portal Setup for Fresh Raspberry Pi OS
# Run with: sudo bash setup.sh
#
# Network Configuration:
#   eth0: DHCP client on your LAN (admin access)
#   wlan0: 192.168.4.1 - Customer WiFi (no gateway, no auto-kick)
#
# Features:
#   - Captive portal with restaurant menu
#   - Queue number system (MAC-based, one order per day)
#   - Admin dashboard on LAN
#   - Clients use cellular data (no gateway provided)
#   - No auto-kick (stay connected)
#   - New Order button when completed
#   - Currently Serving display
#   - MAC address tracking via dnsmasq leases

set -e

echo "================================================"
echo "Restaurant Portal - Complete Setup"
echo "================================================"
echo ""
echo "This will install:"
echo "  • Open WiFi AP: Restaurant_WiFi"
echo "  • Captive Portal with menu"
echo "  • Admin dashboard"
echo "  • No internet gateway (clients use cellular)"
echo "  • No auto-kick (stay connected)"
echo "  • New Order button"
echo "  • Currently Serving display"
echo "  • MAC-based order tracking"
echo ""
echo "Requirements:"
echo "  • Fresh Raspberry Pi OS installation"
echo "  • Ethernet cable connected to your network"
echo "  • Internet access for installation"
echo ""
read -p "Press Enter to continue or Ctrl+C to cancel..."

# ============================================
# STEP 1: Install Required Packages
# ============================================
echo ""
echo "[1/13] Installing required packages..."
apt-get update
apt-get install -y \
    hostapd \
    dnsmasq \
    nginx \
    iptables-persistent \
    python3-pip \
    python3-venv \
    python3-full \
    sqlite3 \
    network-manager \
    rfkill

# ============================================
# STEP 2: Stop Conflicting Services
# ============================================
echo ""
echo "[2/13] Stopping conflicting services..."
systemctl stop hostapd 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true
killall wpa_supplicant hostapd dnsmasq 2>/dev/null || true
sleep 2

# ============================================
# STEP 3: Unblock WiFi
# ============================================
echo ""
echo "[3/13] Unblocking WiFi..."
rfkill unblock all
raspi-config nonint do_wifi_country US

# ============================================
# STEP 4: Configure Network Interfaces
# ============================================
echo ""
echo "[4/13] Configuring network interfaces..."

# Start NetworkManager
systemctl unmask NetworkManager
systemctl enable NetworkManager
systemctl start NetworkManager
sleep 3

# Configure eth0 as DHCP client (for admin access)
echo "Configuring eth0 (LAN) as DHCP client..."
nmcli device set eth0 managed yes
nmcli connection delete "Wired connection 1" 2>/dev/null || true
nmcli connection delete "eth0" 2>/dev/null || true
nmcli connection delete "LAN-Admin" 2>/dev/null || true
nmcli connection add type ethernet con-name "LAN-Admin" ifname eth0 autoconnect yes
nmcli connection up "LAN-Admin" 2>/dev/null || true
sleep 2

# Configure wlan0 with static IP (unmanage from NetworkManager)
echo "Configuring wlan0 (WiFi AP)..."
nmcli device set wlan0 managed no

# Manually set wlan0 IP
ip link set wlan0 down
sleep 1
ip addr flush dev wlan0
ip link set wlan0 up
sleep 1
ip addr add 192.168.4.1/24 dev wlan0

# Make persistent
mkdir -p /etc/network/interfaces.d
cat > /etc/network/interfaces.d/wlan0 << 'EOF'
auto wlan0
iface wlan0 inet static
    address 192.168.4.1
    netmask 255.255.255.0
EOF

# Create wlan0 setup script (FIX FOR DNSMASQ)
echo "Creating wlan0 setup script..."
cat > /usr/local/bin/setup-wlan0.sh << 'EOF'
#!/bin/bash
ip link set wlan0 up
ip addr flush dev wlan0
ip addr add 192.168.4.1/24 dev wlan0
EOF
chmod +x /usr/local/bin/setup-wlan0.sh

# Verify network configuration
echo ""
echo "Network Status:"
echo "  eth0: $(ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || echo 'Getting IP...')"
echo "  wlan0: $(ip -4 addr show wlan0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || echo 'ERROR')"

if ! ip addr show wlan0 | grep -q "192.168.4.1"; then
    echo "❌ ERROR: wlan0 does not have IP 192.168.4.1"
    exit 1
fi

echo "✅ Network interfaces configured"

# ============================================
# STEP 5: Configure hostapd (WiFi AP)
# ============================================
echo ""
echo "[5/13] Configuring hostapd..."

cat > /etc/hostapd/hostapd.conf << 'EOF'
# Basic configuration
interface=wlan0
driver=nl80211
ssid=Restaurant_WiFi

# WiFi settings
hw_mode=g
channel=6
ieee80211n=1
wmm_enabled=1

# Open network (no password)
auth_algs=1
wpa=0

# Country settings
country_code=US
ieee80211d=1

# MAC filtering disabled (no auto-kick)
macaddr_acl=0

# Control interface
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
EOF

cat > /etc/default/hostapd << 'EOF'
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF

# ============================================
# STEP 6: Configure dnsmasq (DHCP/DNS)
# ============================================
echo ""
echo "[6/13] Configuring dnsmasq..."

mv /etc/dnsmasq.conf /etc/dnsmasq.conf.backup 2>/dev/null || true

cat > /etc/dnsmasq.conf << 'EOF'
# Listen only on wlan0
interface=wlan0
bind-interfaces

# DHCP configuration - NO GATEWAY (clients use cellular)
dhcp-range=192.168.4.10,192.168.4.250,255.255.255.0,12h

# Provide DNS (ourselves) but NO gateway
dhcp-option=6,192.168.4.1

# DHCP authoritative
dhcp-authoritative

# DNS - redirect all queries to our portal
address=/#/192.168.4.1

# Don't use upstream DNS
no-resolv

# Security settings
domain-needed
bogus-priv

# Logging
log-dhcp
log-queries
EOF

# Configure dnsmasq to wait for wlan0
echo "Configuring dnsmasq service dependencies..."
mkdir -p /etc/systemd/system/dnsmasq.service.d
cat > /etc/systemd/system/dnsmasq.service.d/wait-for-wlan0.conf << 'EOF'
[Unit]
After=hostapd.service
Requires=hostapd.service

[Service]
ExecStartPre=/usr/local/bin/setup-wlan0.sh
ExecStartPre=/bin/sleep 2
Restart=on-failure
RestartSec=5
EOF

# ============================================
# STEP 7: Disable IP Forwarding
# ============================================
echo ""
echo "[7/13] Disabling IP forwarding (no gateway)..."

sysctl -w net.ipv4.ip_forward=0
echo "net.ipv4.ip_forward=0" > /etc/sysctl.d/90-no-forward.conf

# ============================================
# STEP 8: Configure Firewall
# ============================================
echo ""
echo "[8/13] Configuring firewall..."

iptables -F
iptables -t nat -F
iptables -X

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow ALL from eth0 (admin access from LAN)
iptables -A INPUT -i eth0 -j ACCEPT

# Allow specific services on wlan0 (customer WiFi)
iptables -A INPUT -i wlan0 -p udp --dport 67:68 -j ACCEPT  # DHCP
iptables -A INPUT -i wlan0 -p udp --dport 53 -j ACCEPT     # DNS
iptables -A INPUT -i wlan0 -p tcp --dport 53 -j ACCEPT     # DNS
iptables -A INPUT -i wlan0 -p tcp --dport 80 -j ACCEPT     # HTTP
iptables -A INPUT -i wlan0 -p tcp --dport 443 -j ACCEPT    # HTTPS

# Redirect HTTP/HTTPS to captive portal (only on wlan0)
iptables -t nat -A PREROUTING -i wlan0 -p tcp --dport 80 -j DNAT --to-destination 192.168.4.1:80
iptables -t nat -A PREROUTING -i wlan0 -p tcp --dport 443 -j REDIRECT --to-port 80

# NO FORWARDING between networks
iptables -P FORWARD DROP

netfilter-persistent save

# ============================================
# STEP 9: Create Flask Application
# ============================================
echo ""
echo "[9/13] Creating Flask application..."

mkdir -p /opt/restaurant-portal/static
cd /opt/restaurant-portal

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install flask flask-cors

# Create Flask app with MAC address tracking
cat > app.py << 'PYEOF'
from flask import Flask, request, jsonify, send_from_directory
from flask_cors import CORS
import sqlite3
import time

app = Flask(__name__, static_folder='static')
CORS(app)

DB_PATH = '/opt/restaurant-portal/orders.db'
LEASES_FILE = '/var/lib/misc/dnsmasq.leases'

def get_mac_from_ip(ip_address):
    """Get MAC address from DHCP leases file"""
    try:
        with open(LEASES_FILE, 'r') as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 3:
                    # Format: timestamp MAC IP hostname
                    lease_ip = parts[2]
                    lease_mac = parts[1]
                    if lease_ip == ip_address:
                        return lease_mac.lower()
        
        # Fallback: use IP if MAC not found
        return ip_address
    except Exception as e:
        print(f"Error reading leases: {e}")
        return ip_address

def init_db():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute('''CREATE TABLE IF NOT EXISTS orders
                 (id INTEGER PRIMARY KEY AUTOINCREMENT,
                  queue_number INTEGER,
                  mac_address TEXT,
                  items TEXT,
                  status TEXT DEFAULT 'pending',
                  timestamp INTEGER,
                  notes TEXT)''')
    c.execute('''CREATE TABLE IF NOT EXISTS menu_items
                 (id INTEGER PRIMARY KEY AUTOINCREMENT,
                  name TEXT,
                  description TEXT,
                  price REAL,
                  category TEXT,
                  available BOOLEAN DEFAULT 1)''')
    
    c.execute('SELECT COUNT(*) FROM menu_items')
    if c.fetchone()[0] == 0:
        sample_items = [
            ('Margherita Pizza', 'Classic tomato and mozzarella', 12.99, 'Main', 1),
            ('Caesar Salad', 'Romaine lettuce with Caesar dressing', 8.99, 'Starter', 1),
            ('Cheeseburger', 'Beef patty with cheese and toppings', 10.99, 'Main', 1),
            ('French Fries', 'Crispy golden fries', 4.99, 'Side', 1),
            ('Spaghetti Carbonara', 'Creamy pasta with bacon', 13.99, 'Main', 1),
            ('Chicken Wings', 'Spicy buffalo wings', 9.99, 'Starter', 1),
            ('Onion Rings', 'Crispy fried onion rings', 5.99, 'Side', 1),
            ('Coca Cola', 'Refreshing soft drink', 2.99, 'Drink', 1),
            ('Lemonade', 'Fresh squeezed lemonade', 3.99, 'Drink', 1),
            ('Iced Tea', 'Cold brewed tea', 2.99, 'Drink', 1),
            ('Tiramisu', 'Italian coffee-flavored dessert', 6.99, 'Dessert', 1),
            ('Chocolate Cake', 'Rich chocolate cake', 5.99, 'Dessert', 1),
            ('Ice Cream Sundae', 'Vanilla ice cream with toppings', 4.99, 'Dessert', 1)
        ]
        c.executemany('INSERT INTO menu_items (name, description, price, category, available) VALUES (?, ?, ?, ?, ?)', sample_items)
    
    conn.commit()
    conn.close()

def get_next_queue_number():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute('SELECT MAX(queue_number) FROM orders WHERE date(timestamp, "unixepoch") = date("now")')
    result = c.fetchone()[0]
    conn.close()
    return (result + 1) if result else 1

@app.route('/')
def index():
    return send_from_directory('static', 'customer.html')

@app.route('/admin')
def admin():
    return send_from_directory('static', 'admin.html')

@app.route('/api/menu', methods=['GET'])
def get_menu():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute('SELECT id, name, description, price, category FROM menu_items WHERE available = 1')
    items = [{'id': row[0], 'name': row[1], 'description': row[2], 'price': row[3], 'category': row[4]} 
             for row in c.fetchall()]
    conn.close()
    return jsonify(items)

@app.route('/api/currently-serving', methods=['GET'])
def get_currently_serving():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    # Get the lowest queue number that's ready or preparing
    c.execute('''SELECT MIN(queue_number) FROM orders 
                 WHERE date(timestamp, "unixepoch") = date("now") 
                 AND status IN ("ready", "preparing")''')
    result = c.fetchone()[0]
    conn.close()
    return jsonify({'currently_serving': result})

@app.route('/api/order', methods=['POST'])
def create_order():
    data = request.json
    ip_address = request.headers.get('X-Real-IP', request.remote_addr)
    
    # Get real MAC address from DHCP leases
    mac_address = get_mac_from_ip(ip_address)
    
    print(f"Order from IP: {ip_address}, MAC: {mac_address}")  # Debug
    
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    
    c.execute('SELECT queue_number, status FROM orders WHERE mac_address = ? AND date(timestamp, "unixepoch") = date("now")', (mac_address,))
    existing = c.fetchone()
    
    if existing:
        conn.close()
        return jsonify({'queue_number': existing[0], 'status': existing[1], 'message': 'You already have an order today'})
    
    queue_number = get_next_queue_number()
    items = ','.join([f"{item['name']} x{item['quantity']}" for item in data.get('items', [])])
    
    c.execute('INSERT INTO orders (queue_number, mac_address, items, timestamp, notes) VALUES (?, ?, ?, ?, ?)',
              (queue_number, mac_address, items, int(time.time()), data.get('notes', '')))
    conn.commit()
    conn.close()
    
    return jsonify({'queue_number': queue_number, 'status': 'pending'})

@app.route('/api/order/status', methods=['GET'])
def get_order_status():
    ip_address = request.headers.get('X-Real-IP', request.remote_addr)
    mac_address = get_mac_from_ip(ip_address)
    
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute('SELECT queue_number, status, items FROM orders WHERE mac_address = ? AND date(timestamp, "unixepoch") = date("now")', (mac_address,))
    result = c.fetchone()
    conn.close()
    
    if result:
        return jsonify({'queue_number': result[0], 'status': result[1], 'items': result[2]})
    return jsonify({'error': 'No order found'}), 404

@app.route('/api/order/clear', methods=['POST'])
def clear_order():
    ip_address = request.headers.get('X-Real-IP', request.remote_addr)
    mac_address = get_mac_from_ip(ip_address)
    
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute('DELETE FROM orders WHERE mac_address = ? AND date(timestamp, "unixepoch") = date("now")', (mac_address,))
    conn.commit()
    conn.close()
    
    return jsonify({'success': True})

@app.route('/api/admin/orders', methods=['GET'])
def get_all_orders():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute('SELECT id, queue_number, mac_address, items, status, timestamp, notes FROM orders WHERE date(timestamp, "unixepoch") = date("now") ORDER BY queue_number')
    orders = [{'id': row[0], 'queue_number': row[1], 'mac_address': row[2], 'items': row[3], 
               'status': row[4], 'timestamp': row[5], 'notes': row[6]} for row in c.fetchall()]
    conn.close()
    return jsonify(orders)

@app.route('/api/admin/order/<int:order_id>/status', methods=['PUT'])
def update_order_status(order_id):
    data = request.json
    new_status = data.get('status')
    
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute('UPDATE orders SET status = ? WHERE id = ?', (new_status, order_id))
    conn.commit()
    conn.close()
    
    return jsonify({'success': True})

if __name__ == '__main__':
    init_db()
    app.run(host='0.0.0.0', port=5000)
PYEOF

# Create customer portal HTML with New Order button and Currently Serving
cat > static/customer.html << 'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Restaurant Menu</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: Arial, sans-serif; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); min-height: 100vh; padding: 20px; }
        .container { max-width: 800px; margin: 0 auto; background: white; border-radius: 15px; padding: 30px; box-shadow: 0 10px 40px rgba(0,0,0,0.2); }
        h1 { color: #333; text-align: center; margin-bottom: 10px; }
        .subtitle { text-align: center; color: #666; margin-bottom: 20px; font-size: 14px; }
        .info-box { background: #e3f2fd; border-left: 4px solid #2196f3; padding: 12px; margin-bottom: 20px; border-radius: 5px; font-size: 13px; line-height: 1.5; }
        .currently-serving { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 20px; border-radius: 10px; text-align: center; margin-bottom: 20px; box-shadow: 0 4px 15px rgba(102, 126, 234, 0.3); }
        .currently-serving h3 { font-size: 16px; margin-bottom: 8px; opacity: 0.9; }
        .serving-number { font-size: 48px; font-weight: bold; margin: 5px 0; text-shadow: 2px 2px 4px rgba(0,0,0,0.2); }
        .menu-category { margin-bottom: 25px; }
        .category-title { color: #667eea; font-size: 18px; margin-bottom: 12px; border-bottom: 2px solid #667eea; padding-bottom: 5px; }
        .menu-item { background: #f8f9fa; padding: 12px; margin-bottom: 8px; border-radius: 8px; display: flex; justify-content: space-between; align-items: center; }
        .item-info { flex: 1; }
        .item-name { font-weight: bold; margin-bottom: 3px; font-size: 15px; }
        .item-description { font-size: 13px; color: #666; margin-bottom: 3px; }
        .item-price { color: #667eea; font-weight: bold; font-size: 14px; }
        .item-controls { display: flex; gap: 8px; align-items: center; }
        .qty-btn { background: #667eea; color: white; border: none; width: 32px; height: 32px; border-radius: 5px; cursor: pointer; font-size: 18px; display: flex; align-items: center; justify-content: center; }
        .qty-btn:active { background: #5568d3; }
        .qty-display { min-width: 25px; text-align: center; font-weight: bold; }
        .cart-summary { background: #f8f9fa; padding: 20px; border-radius: 8px; margin-top: 25px; }
        .cart-item { display: flex; justify-content: space-between; margin-bottom: 8px; font-size: 14px; }
        .order-btn { background: #28a745; color: white; border: none; padding: 15px; border-radius: 8px; width: 100%; margin-top: 12px; cursor: pointer; font-size: 16px; font-weight: bold; }
        .order-btn:active { background: #218838; }
        .order-btn:disabled { background: #ccc; cursor: not-allowed; }
        .queue-display { text-align: center; padding: 30px; }
        .queue-number { font-size: 80px; color: #667eea; font-weight: bold; line-height: 1; }
        .status-badge { display: inline-block; padding: 8px 20px; border-radius: 20px; margin-top: 15px; font-size: 16px; font-weight: bold; }
        .status-pending { background: #ffc107; color: #000; }
        .status-preparing { background: #17a2b8; color: white; }
        .status-ready { background: #28a745; color: white; }
        .status-completed { background: #6c757d; color: white; }
        .hidden { display: none; }
        .notes-input { width: 100%; padding: 10px; border: 1px solid #ddd; border-radius: 5px; margin-top: 10px; font-size: 14px; }
        .add-notes-btn { background: #f8f9fa; color: #667eea; border: 2px dashed #667eea; padding: 10px; border-radius: 5px; width: 100%; margin-top: 10px; cursor: pointer; font-size: 14px; }
        .add-notes-btn:active { background: #e9ecef; }
        .refresh-btn { background: #667eea; color: white; border: none; padding: 12px 24px; border-radius: 5px; margin-top: 20px; cursor: pointer; font-size: 14px; }
        .new-order-btn { background: #28a745; color: white; border: none; padding: 12px 24px; border-radius: 5px; margin-top: 15px; cursor: pointer; font-size: 14px; font-weight: bold; }
        .new-order-btn:active { background: #218838; }
        .order-items-display { background: #f8f9fa; padding: 15px; border-radius: 8px; margin-top: 20px; text-align: left; font-size: 14px; line-height: 1.6; }
        .completed-message { background: #d4edda; color: #155724; padding: 15px; border-radius: 8px; margin-top: 20px; border: 1px solid #c3e6cb; text-align: center; font-weight: bold; }
    </style>
</head>
<body>
    <div class="container">
        <div id="menuView">
            <h1>🍽️ Restaurant Menu</h1>
            <p class="subtitle">Order delicious food</p>
            
            <div class="info-box">
                <strong>📱 WiFi Info:</strong> This WiFi doesn't provide internet access. Use your cellular data for browsing. Stay connected to check your order status!
            </div>
            
            <div class="currently-serving" id="currentlyServing">
                <h3>Now Serving</h3>
                <div class="serving-number" id="servingNumber">-</div>
            </div>
            
            <div id="menuContainer"></div>
            
            <div class="cart-summary">
                <h3 style="margin-bottom: 12px;">Your Order</h3>
                <div id="cartItems"></div>
                <button class="add-notes-btn hidden" id="addNotesBtn" onclick="toggleNotes()">📝 Add Special Requests</button>
                <input type="text" class="notes-input hidden" id="orderNotes" placeholder="Special requests or dietary restrictions...">
                <button class="order-btn" id="orderBtn" onclick="placeOrder()">Place Order</button>
            </div>
        </div>
        
        <div id="queueView" class="hidden">
            <div class="currently-serving" id="currentlyServing2">
                <h3>Now Serving</h3>
                <div class="serving-number" id="servingNumber2">-</div>
            </div>
            
            <div class="queue-display">
                <h2 style="margin-bottom: 15px;">Your Queue Number</h2>
                <div class="queue-number" id="queueNumber">-</div>
                <div class="status-badge" id="statusBadge">Pending</div>
                <div id="completedMessage" class="completed-message hidden">
                    🎉 Order Completed! Thank you!
                </div>
                <div class="order-items-display" id="orderItems"></div>
                <button class="refresh-btn" onclick="checkStatus()">🔄 Refresh Status</button>
                <button class="new-order-btn hidden" id="newOrderBtn" onclick="startNewOrder()">🍽️ Place New Order</button>
                <p style="margin-top: 15px; color: #999; font-size: 13px;">Auto-updates every 10 seconds</p>
            </div>
        </div>
    </div>

    <script>
        let menu = [];
        let cart = {};
        let statusCheckInterval;

        async function loadMenu() {
            try {
                const res = await fetch('/api/menu');
                menu = await res.json();
                renderMenu();
                checkExistingOrder();
                updateCurrentlyServing();
            } catch (e) {
                console.error('Failed to load menu:', e);
            }
        }

        async function updateCurrentlyServing() {
            try {
                const res = await fetch('/api/currently-serving');
                const data = await res.json();
                const servingNum = data.currently_serving || '-';
                document.getElementById('servingNumber').textContent = servingNum;
                const serving2 = document.getElementById('servingNumber2');
                if (serving2) serving2.textContent = servingNum;
            } catch (e) {
                console.error('Failed to get currently serving:', e);
            }
        }

        async function checkExistingOrder() {
            try {
                const res = await fetch('/api/order/status');
                if (res.ok) {
                    const data = await res.json();
                    showQueue(data.queue_number, data.status, data.items);
                }
            } catch (e) {}
        }

        async function checkStatus() {
            try {
                const res = await fetch('/api/order/status');
                if (res.ok) {
                    const data = await res.json();
                    updateStatus(data.status);
                    updateCurrentlyServing();
                }
            } catch (e) {}
        }

        function updateStatus(status) {
            document.getElementById('statusBadge').textContent = status.toUpperCase();
            document.getElementById('statusBadge').className = `status-badge status-${status}`;
            
            // Show "New Order" button and completed message if status is completed
            const newOrderBtn = document.getElementById('newOrderBtn');
            const completedMsg = document.getElementById('completedMessage');
            if (status === 'completed') {
                newOrderBtn.classList.remove('hidden');
                completedMsg.classList.remove('hidden');
            } else {
                newOrderBtn.classList.add('hidden');
                completedMsg.classList.add('hidden');
            }
        }

        async function startNewOrder() {
            // Clear the current order
            try {
                await fetch('/api/order/clear', { method: 'POST' });
            } catch (e) {
                console.error('Failed to clear order:', e);
            }
            
            // Stop status checking
            if (statusCheckInterval) {
                clearInterval(statusCheckInterval);
            }
            
            // Reset cart and view
            cart = {};
            document.getElementById('orderNotes').value = '';
            document.getElementById('orderNotes').classList.add('hidden');
            document.getElementById('addNotesBtn').classList.add('hidden');
            document.getElementById('queueView').classList.add('hidden');
            document.getElementById('menuView').classList.remove('hidden');
            renderMenu();
            updateCartSummary();
            updateCurrentlyServing();
        }

        function renderMenu() {
            const categories = [...new Set(menu.map(item => item.category))];
            const container = document.getElementById('menuContainer');
            container.innerHTML = '';
            
            categories.forEach(category => {
                const categoryDiv = document.createElement('div');
                categoryDiv.className = 'menu-category';
                categoryDiv.innerHTML = `<div class="category-title">${category}</div>`;
                
                menu.filter(item => item.category === category).forEach(item => {
                    const itemDiv = document.createElement('div');
                    itemDiv.className = 'menu-item';
                    itemDiv.innerHTML = `
                        <div class="item-info">
                            <div class="item-name">${item.name}</div>
                            <div class="item-description">${item.description}</div>
                            <div class="item-price">$${item.price.toFixed(2)}</div>
                        </div>
                        <div class="item-controls">
                            <button class="qty-btn" onclick="updateCart(${item.id}, -1)">−</button>
                            <span class="qty-display" id="qty-${item.id}">0</span>
                            <button class="qty-btn" onclick="updateCart(${item.id}, 1)">+</button>
                        </div>
                    `;
                    categoryDiv.appendChild(itemDiv);
                });
                
                container.appendChild(categoryDiv);
            });
        }

        function updateCart(itemId, change) {
            cart[itemId] = (cart[itemId] || 0) + change;
            if (cart[itemId] <= 0) delete cart[itemId];
            document.getElementById(`qty-${itemId}`).textContent = cart[itemId] || 0;
            updateCartSummary();
        }

        function updateCartSummary() {
            const cartDiv = document.getElementById('cartItems');
            const orderBtn = document.getElementById('orderBtn');
            const addNotesBtn = document.getElementById('addNotesBtn');
            
            if (Object.keys(cart).length === 0) {
                cartDiv.innerHTML = '<p style="color: #999; font-size: 14px;">Your cart is empty</p>';
                orderBtn.disabled = true;
                addNotesBtn.classList.add('hidden');
                return;
            }
            
            orderBtn.disabled = false;
            addNotesBtn.classList.remove('hidden');
            let html = '';
            let total = 0;
            
            Object.entries(cart).forEach(([itemId, qty]) => {
                const item = menu.find(m => m.id == itemId);
                const subtotal = item.price * qty;
                total += subtotal;
                html += `<div class="cart-item"><span>${item.name} ×${qty}</span><span>${subtotal.toFixed(2)}</span></div>`;
            });
            
            html += `<div class="cart-item" style="border-top: 2px solid #ddd; padding-top: 8px; margin-top: 8px; font-weight: bold;"><span>Total</span><span>${total.toFixed(2)}</span></div>`;
            cartDiv.innerHTML = html;
        }

        function toggleNotes() {
            const notesInput = document.getElementById('orderNotes');
            const addNotesBtn = document.getElementById('addNotesBtn');
            
            if (notesInput.classList.contains('hidden')) {
                notesInput.classList.remove('hidden');
                addNotesBtn.classList.add('hidden');
                notesInput.focus();
            } else {
                notesInput.classList.add('hidden');
                addNotesBtn.classList.remove('hidden');
            }
        }

        async function placeOrder() {
            if (Object.keys(cart).length === 0) return;
            
            const items = Object.entries(cart).map(([itemId, qty]) => ({
                name: menu.find(m => m.id == itemId).name,
                quantity: qty
            }));
            
            const notes = document.getElementById('orderNotes').value;
            
            try {
                const res = await fetch('/api/order', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({items, notes})
                });
                
                const data = await res.json();
                showQueue(data.queue_number, data.status, items.map(i => `${i.name} ×${i.quantity}`).join(', '));
            } catch (e) {
                alert('Failed to place order. Please try again.');
            }
        }

        function showQueue(number, status, items) {
            document.getElementById('menuView').classList.add('hidden');
            document.getElementById('queueView').classList.remove('hidden');
            document.getElementById('queueNumber').textContent = number;
            updateStatus(status);
            document.getElementById('orderItems').innerHTML = `<strong>Your Order:</strong><br>${items}`;
            
            updateCurrentlyServing();
            statusCheckInterval = setInterval(checkStatus, 10000);
        }

        // Update currently serving every 10 seconds
        setInterval(updateCurrentlyServing, 10000);
        
        loadMenu();
    </script>
</body>
</html>
HTMLEOF

# Create admin portal HTML
cat > static/admin.html << 'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Admin Dashboard</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: Arial, sans-serif; background: #f0f2f5; padding: 20px; }
        .container { max-width: 1600px; margin: 0 auto; }
        h1 { text-align: center; margin-bottom: 30px; color: #333; }
        .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 20px; margin-bottom: 30px; }
        .stat-card { background: white; padding: 25px; border-radius: 10px; text-align: center; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
        .stat-number { font-size: 36px; font-weight: bold; color: #667eea; margin-bottom: 8px; }
        .stat-label { color: #666; font-size: 14px; }
        .orders-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 20px; }
        .order-card { background: white; padding: 20px; border-radius: 10px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); transition: transform 0.2s; }
        .order-card:hover { transform: translateY(-2px); box-shadow: 0 4px 12px rgba(0,0,0,0.15); }
        .queue-number { font-size: 40px; font-weight: bold; color: #667eea; margin-bottom: 10px; }
        .order-time { color: #999; font-size: 12px; margin-bottom: 10px; }
        .mac-address { color: #999; font-size: 11px; font-family: monospace; margin-bottom: 12px; }
        .order-items { background: #f8f9fa; padding: 12px; border-radius: 6px; margin: 12px 0; font-size: 14px; line-height: 1.6; }
        .order-notes { background: #fff9e6; padding: 10px; border-radius: 6px; margin: 12px 0; font-size: 13px; font-style: italic; color: #856404; }
        .status-select { width: 100%; padding: 12px; border: 2px solid; border-radius: 6px; font-size: 14px; font-weight: bold; cursor: pointer; margin-top: 12px; }
        .status-pending { border-color: #ffc107; background: #fff9e6; color: #856404; }
        .status-preparing { border-color: #17a2b8; background: #e6f7f9; color: #0c5460; }
        .status-ready { border-color: #28a745; background: #e6f4ea; color: #155724; }
        .status-completed { border-color: #6c757d; background: #f0f0f0; color: #383d41; }
        .no-orders { text-align: center; padding: 60px; color: #999; font-size: 18px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>📊 Restaurant Order Management</h1>
        
        <div class="stats">
            <div class="stat-card">
                <div class="stat-number" id="totalOrders">0</div>
                <div class="stat-label">Total Orders</div>
            </div>
            <div class="stat-card">
                <div class="stat-number" id="pendingOrders">0</div>
                <div class="stat-label">Pending</div>
            </div>
            <div class="stat-card">
                <div class="stat-number" id="preparingOrders">0</div>
                <div class="stat-label">Preparing</div>
            </div>
            <div class="stat-card">
                <div class="stat-number" id="readyOrders">0</div>
                <div class="stat-label">Ready</div>
            </div>
            <div class="stat-card">
                <div class="stat-number" id="completedOrders">0</div>
                <div class="stat-label">Completed</div>
            </div>
        </div>
        
        <div class="orders-grid" id="ordersContainer">
            <div class="no-orders">No orders yet today</div>
        </div>
    </div>

    <script>
        async function loadOrders() {
            try {
                const res = await fetch('/api/admin/orders');
                const orders = await res.json();
                
                const stats = {pending: 0, preparing: 0, ready: 0, completed: 0};
                orders.forEach(o => stats[o.status]++);
                
                document.getElementById('totalOrders').textContent = orders.length;
                document.getElementById('pendingOrders').textContent = stats.pending;
                document.getElementById('preparingOrders').textContent = stats.preparing;
                document.getElementById('readyOrders').textContent = stats.ready;
                document.getElementById('completedOrders').textContent = stats.completed;
                
                const container = document.getElementById('ordersContainer');
                
                if (orders.length === 0) {
                    container.innerHTML = '<div class="no-orders">No orders yet today</div>';
                    return;
                }
                
                container.innerHTML = orders.map(order => `
                    <div class="order-card">
                        <div class="queue-number">#${order.queue_number}</div>
                        <div class="order-time">${new Date(order.timestamp * 1000).toLocaleString()}</div>
                        <div class="mac-address">MAC: ${order.mac_address}</div>
                        <div class="order-items">${order.items}</div>
                        ${order.notes ? `<div class="order-notes">📝 ${order.notes}</div>` : ''}
                        <select class="status-select status-${order.status}" onchange="updateStatus(${order.id}, this.value)">
                            <option value="pending" ${order.status === 'pending' ? 'selected' : ''}>⏳ Pending</option>
                            <option value="preparing" ${order.status === 'preparing' ? 'selected' : ''}>👨‍🍳 Preparing</option>
                            <option value="ready" ${order.status === 'ready' ? 'selected' : ''}>✅ Ready for Pickup</option>
                            <option value="completed" ${order.status === 'completed' ? 'selected' : ''}>✔️ Completed</option>
                        </select>
                    </div>
                `).join('');
            } catch (e) {
                console.error('Failed to load orders:', e);
            }
        }

        async function updateStatus(orderId, newStatus) {
            try {
                await fetch(`/api/admin/order/${orderId}/status`, {
                    method: 'PUT',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({status: newStatus})
                });
                loadOrders();
            } catch (e) {
                console.error('Failed to update status:', e);
            }
        }

        loadOrders();
        setInterval(loadOrders, 5000);
    </script>
</body>
</html>
HTMLEOF

# ============================================
# STEP 10: Create Systemd Service
# ============================================
echo ""
echo "[10/13] Creating systemd service..."

cat > /etc/systemd/system/restaurant-portal.service << 'EOF'
[Unit]
Description=Restaurant Portal Application
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/restaurant-portal
Environment="PATH=/opt/restaurant-portal/venv/bin"
ExecStart=/opt/restaurant-portal/venv/bin/python /opt/restaurant-portal/app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# ============================================
# STEP 11: Configure Nginx
# ============================================
echo ""
echo "[11/13] Configuring nginx..."

cat > /etc/nginx/sites-available/default << 'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    # Captive portal detection endpoints
    location = /generate_204 {
        return 302 http://192.168.4.1/;
    }
    
    location = /gen_204 {
        return 302 http://192.168.4.1/;
    }

    location = /hotspot-detect.html {
        return 302 http://192.168.4.1/;
    }
    
    location = /connecttest.txt {
        return 302 http://192.168.4.1/;
    }

    location = /ncsi.txt {
        return 302 http://192.168.4.1/;
    }

    # Main application
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_redirect off;
    }
}
EOF

# ============================================
# STEP 12: Enable and Start Services
# ============================================
echo ""
echo "[12/13] Enabling services..."

systemctl daemon-reload
systemctl unmask hostapd
systemctl enable hostapd
systemctl enable dnsmasq
systemctl enable nginx
systemctl enable restaurant-portal

echo ""
echo "Starting services..."

# Start hostapd
systemctl start hostapd
sleep 3

if systemctl is-active --quiet hostapd; then
    echo "✅ hostapd started"
    if iw dev wlan0 info 2>/dev/null | grep -q "type AP"; then
        echo "✅ WiFi AP mode active"
    fi
else
    echo "❌ hostapd failed"
    journalctl -u hostapd -n 20 --no-pager
fi

# Start dnsmasq
systemctl start dnsmasq
sleep 2
systemctl is-active --quiet dnsmasq && echo "✅ dnsmasq started" || echo "❌ dnsmasq failed"

# Start nginx
systemctl start nginx
systemctl is-active --quiet nginx && echo "✅ nginx started" || echo "❌ nginx failed"

# Start Flask app
systemctl start restaurant-portal
sleep 2
systemctl is-active --quiet restaurant-portal && echo "✅ Flask app started" || echo "❌ Flask app failed"

# ============================================
# STEP 13: Verify Setup
# ============================================
echo ""
echo "[13/13] Verifying setup..."

# Check if leases file is accessible
if [ -r /var/lib/misc/dnsmasq.leases ]; then
    echo "✅ DHCP leases file accessible"
else
    echo "⚠️  DHCP leases file not yet created (will be created when first client connects)"
fi

# ============================================
# Installation Complete
# ============================================
echo ""
echo "================================================"
echo "✅ Installation Complete!"
echo "================================================"
echo ""
echo "Network Configuration:"
echo "  📡 WiFi AP (wlan0): 192.168.4.1"
echo "  🔌 LAN (eth0): $(ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || echo 'Getting IP...')"
echo ""
echo "Access Points:"
echo "  🍽️ Customer WiFi: Restaurant_WiFi (open, no password)"
echo "  👥 Customer Portal: http://192.168.4.1"
echo "  👨‍💼 Admin Portal: http://$(ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || echo '[ETH0-IP]')/admin"
echo ""
echo "Features:"
echo "  ✅ No auto-kick (stay connected)"
echo "  ✅ No gateway (use cellular for internet)"
echo "  ✅ Captive portal with menu"
echo "  ✅ Queue number system (MAC-based)"
echo "  ✅ Real-time order updates"
echo "  ✅ Currently Serving display"
echo "  ✅ New Order button (when completed)"
echo "  ✅ Admin dashboard"
echo ""
echo "How It Works:"
echo "  1. Customer connects to Restaurant_WiFi"
echo "  2. Captive portal appears with menu"
echo "  3. Customer sees currently serving number"
echo "  4. Customer places order, gets queue #"
echo "  5. Customer STAYS connected"
echo "  6. Customer uses cellular for internet"
echo "  7. Customer can refresh to see order status"
echo "  8. When completed, 'New Order' button appears"
echo "  9. Admin updates status from dashboard"
echo ""
echo "Monitoring Commands:"
echo "  • hostapd logs: sudo journalctl -u hostapd -f"
echo "  • dnsmasq logs: sudo journalctl -u dnsmasq -f"
echo "  • Flask app logs: sudo journalctl -u restaurant-portal -f"
echo "  • WiFi clients: sudo iw dev wlan0 station dump"
echo "  • DHCP leases: cat /var/lib/misc/dnsmasq.leases"
echo ""
echo "Database Access:"
echo "  sqlite3 /opt/restaurant-portal/orders.db"
echo ""
echo "System will auto-start on boot."
echo ""
read -p "Reboot now to ensure everything works? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    reboot
fi
