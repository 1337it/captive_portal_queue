# 🍽️ Restaurant WiFi Portal

A complete captive portal solution for restaurants that provides a WiFi ordering system without internet access. Customers stay connected to WiFi while using their cellular data for internet, enabling real-time order status updates.

## ✨ Features

- **Open WiFi Access Point** - No password required
- **Captive Portal** - Automatic redirect to menu on connection
- **Digital Menu** - Beautiful, mobile-responsive ordering interface
- **Queue System** - MAC address-based order tracking (one order per day per device)
- **Real-time Updates** - Order status updates every 10 seconds
- **Currently Serving Display** - Shows which order number is being prepared
- **Admin Dashboard** - Manage orders and update statuses from LAN
- **No Internet Gateway** - Customers use cellular data while staying connected to WiFi
- **No Auto-Kick** - Customers stay connected throughout their visit
- **New Order Feature** - Place another order after completion

## 🎯 Use Case

Perfect for restaurants that want to:
- Provide WiFi for order status tracking
- Avoid bandwidth costs from customer internet usage
- Modernize ordering without expensive POS systems
- Track orders by device (MAC address)
- Keep customers engaged throughout their visit

## 📋 Requirements

- Raspberry Pi (3B+, 4, or 5 recommended)
- Fresh Raspberry Pi OS installation
- Ethernet connection to your network
- Internet access during installation (for packages)
- WiFi adapter (built-in on most Raspberry Pi models)

## 🚀 Quick Installation

```bash
# Download the setup script
wget https://raw.githubusercontent.com/YOUR_USERNAME/restaurant-wifi-portal/main/setup.sh

# Make it executable
chmod +x setup.sh

# Run as root
sudo bash setup.sh
```

The script will:
1. Install all required packages
2. Configure network interfaces
3. Set up WiFi access point
4. Configure captive portal
5. Create Flask application
6. Set up admin dashboard
7. Configure auto-start on boot

**Installation takes about 5-10 minutes.**

## 🌐 Network Configuration

After installation:

- **WiFi AP (wlan0)**: `192.168.4.1`
  - SSID: `Restaurant_WiFi` (open, no password)
  - DHCP range: `192.168.4.10` - `192.168.4.250`
  
- **LAN (eth0)**: DHCP client on your network
  - Admin access only
  - Gets IP from your router

## 📱 Access Points

### For Customers (WiFi)
```
http://192.168.4.1
```
- Connect to `Restaurant_WiFi`
- Captive portal opens automatically
- Browse menu and place orders
- Check order status in real-time

### For Staff (LAN)
```
http://[ETH0-IP]/admin
```
- Access from any device on your network
- View all today's orders
- Update order statuses
- Real-time dashboard updates

## 🎨 How It Works

1. **Customer connects** to `Restaurant_WiFi`
2. **Captive portal** appears automatically with menu
3. **Customer browses** menu and adds items to cart
4. **Customer places order** and receives queue number
5. **Customer stays connected** to WiFi (no disconnect)
6. **Customer uses cellular** for internet browsing
7. **Order status updates** automatically every 10 seconds
8. **Staff updates status** from admin dashboard
9. **Customer sees updates** in real-time
10. **Order completed** - customer can place new order

## 🛠️ Configuration

### Change WiFi Name
Edit `/etc/hostapd/hostapd.conf`:
```bash
ssid=YOUR_WIFI_NAME
```

### Change WiFi Password (if needed)
Edit `/etc/hostapd/hostapd.conf`:
```bash
wpa=2
wpa_passphrase=YOUR_PASSWORD
wpa_key_mgmt=WPA-PSK
```

### Customize Menu
Edit menu items in the database:
```bash
sqlite3 /opt/restaurant-portal/orders.db
```

Or modify the initial menu in `app.py` before first run.

### Change IP Address
Edit `/usr/local/bin/setup-wlan0.sh`:
```bash
ip addr add YOUR_IP/24 dev wlan0
```

Also update:
- `/etc/dnsmasq.conf`
- `/etc/network/interfaces.d/wlan0`
- `iptables` rules in setup script

## 📊 Monitoring

### Service Status
```bash
# Check all services
sudo systemctl status hostapd
sudo systemctl status dnsmasq
sudo systemctl status nginx
sudo systemctl status restaurant-portal

# View logs
sudo journalctl -u hostapd -f
sudo journalctl -u dnsmasq -f
sudo journalctl -u restaurant-portal -f
```

### Connected Clients
```bash
# WiFi clients
sudo iw dev wlan0 station dump

# DHCP leases
cat /var/lib/misc/dnsmasq.leases
```

### Database Access
```bash
sqlite3 /opt/restaurant-portal/orders.db

# View today's orders
SELECT * FROM orders WHERE date(timestamp, 'unixepoch') = date('now');

# View menu items
SELECT * FROM menu_items;
```

## 🔧 Troubleshooting

### WiFi Not Appearing
```bash
# Check if hostapd is running
sudo systemctl status hostapd

# Check if wlan0 has IP
ip addr show wlan0

# Manually restart services
sudo systemctl restart hostapd
sudo systemctl restart dnsmasq
```

### Captive Portal Not Opening
```bash
# Check nginx
sudo systemctl status nginx

# Check Flask app
sudo systemctl status restaurant-portal

# Test portal locally
curl http://192.168.4.1
```

### Orders Not Saving
```bash
# Check Flask logs
sudo journalctl -u restaurant-portal -n 50

# Check database permissions
ls -la /opt/restaurant-portal/orders.db

# Restart Flask app
sudo systemctl restart restaurant-portal
```

### MAC Address Not Tracking
```bash
# Check DHCP leases file
cat /var/lib/misc/dnsmasq.leases

# Check dnsmasq logs
sudo journalctl -u dnsmasq -n 50
```

## 📁 File Structure

```
/opt/restaurant-portal/
├── app.py                    # Flask application
├── orders.db                 # SQLite database
├── venv/                     # Python virtual environment
└── static/
    ├── customer.html         # Customer portal
    └── admin.html           # Admin dashboard

/etc/hostapd/
└── hostapd.conf             # WiFi AP configuration

/etc/dnsmasq.conf            # DHCP/DNS configuration

/etc/nginx/sites-available/
└── default                  # Nginx configuration

/usr/local/bin/
└── setup-wlan0.sh          # Network setup script

/etc/systemd/system/
├── restaurant-portal.service
└── dnsmasq.service.d/
    └── wait-for-wlan0.conf
```

## 🔒 Security Notes

- WiFi is **open** by default (no password)
- No internet access provided to customers
- Admin dashboard only accessible from LAN
- MAC addresses are logged for order tracking
- Orders reset daily

## 🚀 Future Enhancements

- [ ] Add payment integration
- [ ] SMS notifications when order ready
- [ ] Multi-language support
- [ ] Printer integration
- [ ] Table number assignment
- [ ] Order history reports
- [ ] Analytics dashboard
- [ ] Multiple restaurant locations

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

Built with:
- Flask
- SQLite
- Nginx
- hostapd
- dnsmasq

## 💬 Support

For issues, questions, or suggestions, please open an issue on GitHub.

## 📸 Screenshots

### Customer Portal
![Customer Menu](screenshots/customer-menu.png)
![Order Status](screenshots/order-status.png)

### Admin Dashboard
![Admin Dashboard](screenshots/admin-dashboard.png)

---

Made with ❤️ for restaurants everywhere
