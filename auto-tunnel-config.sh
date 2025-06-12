#!/bin/bash
# auto-tunnel-config.sh - Otomatis membuat konfigurasi Cloudflare Tunnel

set -e

# Warna untuk output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Fungsi untuk print dengan warna
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_menu() { echo -e "${CYAN}$1${NC}"; }
print_verbose() { 
    if [ "$VERBOSE" = true ]; then
        echo -e "${CYAN}[VERBOSE]${NC} $1"
    fi
}

# Default values
DEFAULT_DOMAIN="konxc.space"
DEFAULT_LOCAL_PORT="5000"
CLOUDFLARED_DIR="$HOME/.cloudflared"
CONFIG_FILE="$CLOUDFLARED_DIR/config.yml"
VERBOSE=false

# Fungsi untuk input dengan default value
read_with_default() {
    local prompt="$1"
    local default="$2"
    local result

    # flush menggunakan printf ke stderr jika perlu
    printf "%s [%s]: " "$prompt" "$default" >&2
    read result
    echo "${result:-$default}"
}

# Fungsi untuk validasi input - DIPERBAIKI untuk mengizinkan tanda hubung
validate_tunnel_name() {
    local name="$1"
    # Mengizinkan huruf, angka, dan tanda hubung (-), tetapi tidak boleh dimulai atau diakhiri dengan tanda hubung
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$ ]] && [[ ! "$name" =~ ^[a-zA-Z0-9]$ ]]; then
        print_error "Nama tunnel hanya boleh mengandung huruf, angka, dan tanda hubung (-)"
        print_error "Tidak boleh dimulai atau diakhiri dengan tanda hubung"
        return 1
    fi
    return 0
}

validate_domain() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        print_error "Format domain tidak valid"
        return 1
    fi
    return 0
}

validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        print_error "Port harus berupa angka antara 1-65535"
        return 1
    fi
    return 0
}

# Fungsi untuk cek apakah cloudflared terinstall
check_cloudflared() {
    print_verbose "Mengecek instalasi cloudflared..."
    if ! command -v cloudflared &> /dev/null; then
        print_error "Cloudflared tidak terinstall!"
        echo "Install dengan perintah:"
        echo "wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb"
        echo "sudo dpkg -i cloudflared-linux-amd64.deb"
        exit 1
    fi
    
    if [ "$VERBOSE" = true ]; then
        local version=$(cloudflared --version 2>/dev/null | head -1)
        print_verbose "Cloudflared ditemukan: $version"
    fi
}

# Fungsi untuk cek apakah sudah login
check_cloudflared_auth() {
    print_verbose "Mengecek autentikasi Cloudflare..."
    if [ ! -f "$CLOUDFLARED_DIR/cert.pem" ]; then
        print_error "Belum login ke Cloudflare!"
        echo "Login dengan perintah: cloudflared tunnel login"
        exit 1
    fi
    print_verbose "File sertifikat ditemukan: $CLOUDFLARED_DIR/cert.pem"
}

# Fungsi untuk mendapatkan daftar DNS routes dari tunnel tertentu
get_tunnel_dns_routes() {
    local tunnel_name="$1"
    print_verbose "Mencari DNS routes untuk tunnel: $tunnel_name"
    
    # Sayangnya, cloudflared tidak memiliki command langsung untuk list DNS routes
    # Kita akan mencoba mencari dari config Cloudflare atau dari logs
    # Sebagai workaround, kita bisa cek dari file config yang ada
    
    local routes=()
    
    # Cek dari config file yang ada
    if [ -f "$CONFIG_FILE" ]; then
        local existing_hostnames=$(grep -A 20 "ingress:" "$CONFIG_FILE" | grep "hostname:" | cut -d':' -f2 | tr -d ' ')
        if [ -n "$existing_hostnames" ]; then
            while IFS= read -r hostname; do
                if [ -n "$hostname" ]; then
                    routes+=("$hostname")
                fi
            done <<< "$existing_hostnames"
        fi
    fi
    
    # Output routes yang ditemukan
    for route in "${routes[@]}"; do
        echo "$route"
    done
}

# Fungsi untuk mendapatkan daftar tunnel yang tersedia
get_available_tunnels() {
    print_verbose "Mengambil daftar tunnel yang tersedia..."
    
    # Coba menggunakan JSON output dengan jq
    if command -v jq &> /dev/null; then
        print_verbose "Menggunakan jq untuk parsing JSON output..."
        local json_output=$(cloudflared tunnel list --output json 2>/dev/null)
        if [ -n "$json_output" ] && [ "$json_output" != "null" ]; then
            print_verbose "JSON output berhasil diambil, melakukan parsing..."
            local result=$(echo "$json_output" | jq -r '.[] | "\(.name)|\(.id)"' 2>/dev/null)
            if [ -n "$result" ]; then
                print_verbose "Parsing JSON berhasil, ditemukan $(echo "$result" | wc -l) tunnel(s)"
                echo "$result"
                return
            fi
        fi
        print_verbose "JSON parsing gagal, menggunakan fallback..."
    else
        print_verbose "jq tidak tersedia, menggunakan parsing manual..."
    fi
    
    # Fallback: parsing manual dari output tabel
    print_verbose "Melakukan parsing manual dari output tabel..."
    local count=0
    cloudflared tunnel list 2>/dev/null | tail -n +3 | while read -r line; do
        if [ -n "$line" ] && [[ ! "$line" =~ ^ID.*NAME.*CREATED ]]; then
            # Parse line format: ID NAME CREATED CONNECTIONS
            local tunnel_id=$(echo "$line" | awk '{print $1}')
            local tunnel_name=$(echo "$line" | awk '{print $2}')
            
            if [ -n "$tunnel_id" ] && [ -n "$tunnel_name" ] && [[ "$tunnel_id" =~ ^[a-f0-9-]{36}$ ]]; then
                echo "${tunnel_name}|${tunnel_id}"
                ((count++))
            fi
        fi
    done
    
    if [ "$VERBOSE" = true ] && [ $count -gt 0 ]; then
        print_verbose "Parsing manual berhasil, ditemukan $count tunnel(s)"
    fi
}

# Fungsi untuk mendapatkan tunnel ID berdasarkan nama
get_tunnel_id() {
    local tunnel_name="$1"
    
    # Coba menggunakan JSON output dengan jq
    if command -v jq &> /dev/null; then
        local json_output=$(cloudflared tunnel list --output json 2>/dev/null)
        if [ -n "$json_output" ] && [ "$json_output" != "null" ]; then
            local tunnel_id=$(echo "$json_output" | jq -r ".[] | select(.name == \"$tunnel_name\") | .id" 2>/dev/null)
            if [ -n "$tunnel_id" ] && [ "$tunnel_id" != "null" ]; then
                echo "$tunnel_id"
                return
            fi
        fi
    fi
    
    # Fallback: parsing manual dari output tabel
    cloudflared tunnel list 2>/dev/null | tail -n +3 | while read -r line; do
        if [ -n "$line" ] && [[ ! "$line" =~ ^ID.*NAME.*CREATED ]]; then
            local tunnel_id=$(echo "$line" | awk '{print $1}')
            local name=$(echo "$line" | awk '{print $2}')
            
            if [ "$name" = "$tunnel_name" ] && [[ "$tunnel_id" =~ ^[a-f0-9-]{36}$ ]]; then
                echo "$tunnel_id"
                return
            fi
        fi
    done
}

# Fungsi untuk cek apakah tunnel sudah ada
tunnel_exists() {
    local tunnel_name="$1"
    local tunnel_id=$(get_tunnel_id "$tunnel_name")
    [ -n "$tunnel_id" ] && echo "$tunnel_id" || echo ""
}

# Fungsi untuk cek apakah config sudah ada dengan tunnel yang sama
config_exists_for_tunnel() {
    local tunnel_name="$1"
    if [ -f "$CONFIG_FILE" ]; then
        local existing_tunnel_id=$(grep "^tunnel:" "$CONFIG_FILE" 2>/dev/null | cut -d' ' -f2)
        if [ -n "$existing_tunnel_id" ]; then
            # Cek apakah tunnel ID ini milik tunnel dengan nama yang sama
            local existing_tunnel_name=""
            
            # Coba menggunakan JSON output dengan jq
            if command -v jq &> /dev/null; then
                local json_output=$(cloudflared tunnel list --output json 2>/dev/null)
                if [ -n "$json_output" ] && [ "$json_output" != "null" ]; then
                    existing_tunnel_name=$(echo "$json_output" | jq -r ".[] | select(.id == \"$existing_tunnel_id\") | .name" 2>/dev/null)
                fi
            fi
            
            # Fallback: parsing manual jika jq tidak berhasil
            if [ -z "$existing_tunnel_name" ] || [ "$existing_tunnel_name" = "null" ]; then
                existing_tunnel_name=$(cloudflared tunnel list 2>/dev/null | tail -n +3 | while read -r line; do
                    if [ -n "$line" ] && [[ ! "$line" =~ ^ID.*NAME.*CREATED ]]; then
                        local tunnel_id=$(echo "$line" | awk '{print $1}')
                        local name=$(echo "$line" | awk '{print $2}')
                        
                        if [ "$tunnel_id" = "$existing_tunnel_id" ]; then
                            echo "$name"
                            return
                        fi
                    fi
                done)
            fi
            
            if [ "$existing_tunnel_name" = "$tunnel_name" ]; then
                return 0
            fi
        fi
    fi
    return 1
}

# Fungsi untuk menampilkan menu pilihan tunnel
show_tunnel_menu() {
    local tunnels_data=$(get_available_tunnels)
    local counter=1
    declare -a tunnel_names
    declare -a tunnel_ids
    
    echo ""
    print_menu "📋 Pilih tunnel yang akan dikonfigurasi:"
    # echo ""
    
    # Tampilkan tunnel yang tersedia
    if [ -n "$tunnels_data" ]; then
        while IFS='|' read -r tunnel_name tunnel_id; do
            if [ -n "$tunnel_name" ] && [ -n "$tunnel_id" ]; then
                echo "  $counter) $tunnel_name (ID: ${tunnel_id:0:8}...)"
                tunnel_names[$counter]="$tunnel_name"
                tunnel_ids[$counter]="$tunnel_id"
                ((counter++))
            fi
        done <<< "$tunnels_data"
    fi
    
    # Tambahkan opsi untuk membuat tunnel baru
    echo "  $counter) 🆕 Buat tunnel baru"
    local create_new_option=$counter
    
    echo ""
    echo -n "Pilih nomor (1-$counter): "
    read choice
    
    # Validasi input
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt $counter ]; then
        echo ""
        print_error "Pilihan tidak valid!"
        return 1
    fi
    
    # Proses pilihan
    if [ "$choice" -eq "$create_new_option" ]; then
        # Buat tunnel baru
        echo ""
        while true; do
            echo -n "Tulis nama tunnel anda: "
            read new_tunnel_name
            if [ -n "$new_tunnel_name" ] && validate_tunnel_name "$new_tunnel_name"; then
                # Cek apakah nama sudah digunakan
                if [ -n "$(get_tunnel_id "$new_tunnel_name")" ]; then
                    print_error "Nama tunnel '$new_tunnel_name' sudah digunakan!"
                    continue
                fi
                SELECTED_TUNNEL_NAME="$new_tunnel_name"
                SELECTED_TUNNEL_ID=""
                TUNNEL_MODE="create"
                break
            fi
        done
    else
        # Gunakan tunnel yang sudah ada
        SELECTED_TUNNEL_NAME="${tunnel_names[$choice]}"
        SELECTED_TUNNEL_ID="${tunnel_ids[$choice]}"
        TUNNEL_MODE="existing"
    fi
    
    return 0
}

# Fungsi untuk menampilkan menu pilihan subdomain
show_subdomain_menu() {
    local tunnel_name="$1"
    local base_domain="$2"
    
    echo ""
    print_menu "🌐 Pilih konfigurasi subdomain untuk tunnel '$tunnel_name':"
    # echo ""
    
    # Cari subdomain yang sudah pernah dibuat (dari config yang ada)
    local existing_routes=($(get_tunnel_dns_routes "$tunnel_name"))
    local counter=1
    declare -a available_subdomains
    
    # Tampilkan subdomain yang sudah ada
    if [ ${#existing_routes[@]} -gt 0 ]; then
        print_info "Subdomain yang sudah terkonfigurasi:"
        for route in "${existing_routes[@]}"; do
            echo "  $counter) $route (sudah ada)"
            available_subdomains[$counter]="$route"
            ((counter++))
        done
        echo ""
    fi
    
    # Opsi untuk membuat subdomain baru
    echo "  $counter) 🆕 Buat subdomain baru"
    local create_new_subdomain=$counter
    ((counter++))
    
    # Opsi untuk input manual hostname lengkap
    echo "  $counter) ✏️  Input hostname lengkap manual"
    local manual_hostname=$counter
    
    # echo ""
    echo -n "Pilih nomor (1-$counter): "
    read subdomain_choice
    
    # Validasi input
    if [[ ! "$subdomain_choice" =~ ^[0-9]+$ ]] || [ "$subdomain_choice" -lt 1 ] || [ "$subdomain_choice" -gt $counter ]; then
        print_error "Pilihan tidak valid!"
        return 1
    fi
    
    # Proses pilihan
    if [ "$subdomain_choice" -eq "$create_new_subdomain" ]; then
        # Buat subdomain baru
        echo ""
        while true; do
            echo -n "Masukkan nama subdomain: "
            read new_subdomain
            if [ -n "$new_subdomain" ]; then
                # Validasi subdomain (hanya nama, bukan FQDN)
                if [[ "$new_subdomain" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$ ]] || [[ "$new_subdomain" =~ ^[a-zA-Z0-9]$ ]]; then
                    SELECTED_HOSTNAME="$new_subdomain.$base_domain"
                    SUBDOMAIN_MODE="create"
                    break
                else
                    print_error "Format subdomain tidak valid. Gunakan hanya huruf, angka, dan tanda hubung."
                fi
            fi
        done
    elif [ "$subdomain_choice" -eq "$manual_hostname" ]; then
        # Input hostname lengkap manual
        echo ""
        while true; do
            echo -n "Masukkan hostname lengkap (contoh: api.example.com): "
            read manual_host
            if [ -n "$manual_host" ] && validate_domain "$manual_host"; then
                SELECTED_HOSTNAME="$manual_host"
                SUBDOMAIN_MODE="manual"
                break
            fi
        done
    else
        # Gunakan subdomain yang sudah ada
        SELECTED_HOSTNAME="${available_subdomains[$subdomain_choice]}"
        SUBDOMAIN_MODE="existing"
        
        print_warning "Menggunakan kembali hostname: $SELECTED_HOSTNAME"
        print_warning "Ini akan mengganti konfigurasi yang sudah ada!"
        echo ""
        read -p "Lanjutkan? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    return 0
}

# Fungsi untuk membuat tunnel baru
create_tunnel() {
    local tunnel_name="$1"
    print_info "Membuat tunnel baru: $tunnel_name"
    print_verbose "Menjalankan: cloudflared tunnel create $tunnel_name"
    
    local output=$(cloudflared tunnel create "$tunnel_name" 2>&1)
    local exit_code=$?
    
    if [ "$VERBOSE" = true ]; then
        print_verbose "Output command cloudflared tunnel create:"
        echo "$output" | while IFS= read -r line; do
            print_verbose "$line"
        done
        print_verbose "Exit code: $exit_code"
    fi
    
    if [ $exit_code -eq 0 ]; then
        local tunnel_id=$(echo "$output" | grep -oP 'Created tunnel \K[a-f0-9-]+' || get_tunnel_id "$tunnel_name")
        print_success "Tunnel berhasil dibuat dengan ID: $tunnel_id"
        print_verbose "Tunnel credentials file: $CLOUDFLARED_DIR/$tunnel_id.json"
        echo "$tunnel_id"
    else
        print_error "Gagal membuat tunnel: $output"
        exit 1
    fi
}

# Fungsi untuk setup DNS route
setup_dns_route() {
    local tunnel_name="$1"
    local hostname="$2"
    
    print_info "Mengatur DNS route untuk $hostname"
    print_verbose "Menjalankan: cloudflared tunnel route dns $tunnel_name $hostname"
    
    local output=$(cloudflared tunnel route dns "$tunnel_name" "$hostname" 2>&1)
    local exit_code=$?
    
    if [ "$VERBOSE" = true ]; then
        print_verbose "Output command cloudflared tunnel route dns:"
        echo "$output" | while IFS= read -r line; do
            print_verbose "$line"
        done
        print_verbose "Exit code: $exit_code"
    fi
    
    if [ $exit_code -eq 0 ]; then
        print_success "DNS route berhasil dibuat: $hostname"
    else
        if echo "$output" | grep -q "already exists"; then
            print_warning "DNS route sudah ada untuk $hostname"
        else
            print_error "Gagal membuat DNS route: $output"
            exit 1
        fi
    fi
}

# Fungsi untuk membuat config file
create_config_file() {
    local tunnel_id="$1"
    local hostname="$2"
    local local_port="$3"
    
    print_verbose "Memulai pembuatan config file..."
    print_verbose "Parameter yang diterima:"
    print_verbose "  - Tunnel ID: $tunnel_id"
    print_verbose "  - Hostname: $hostname"
    print_verbose "  - Local Port: $local_port"
    print_verbose "  - Config File Path: $CONFIG_FILE"
    print_verbose "  - Credentials File: $CLOUDFLARED_DIR/$tunnel_id.json"
    
    # Buat direktori jika belum ada
    print_verbose "Mengecek dan membuat direktori $CLOUDFLARED_DIR jika belum ada..."
    if [ ! -d "$CLOUDFLARED_DIR" ]; then
        print_verbose "Direktori $CLOUDFLARED_DIR tidak ada, membuat direktori..."
        mkdir -p "$CLOUDFLARED_DIR"
        print_verbose "Direktori berhasil dibuat dengan permission: $(ls -ld "$CLOUDFLARED_DIR" | awk '{print $1}')"
    else
        print_verbose "Direktori $CLOUDFLARED_DIR sudah ada"
    fi
    
    # Cek apakah credentials file ada
    local credentials_file="$CLOUDFLARED_DIR/$tunnel_id.json"
    if [ -f "$credentials_file" ]; then
        print_verbose "Credentials file ditemukan: $credentials_file"
        print_verbose "Ukuran file: $(du -h "$credentials_file" | cut -f1)"
    else
        print_verbose "WARNING: Credentials file tidak ditemukan: $credentials_file"
    fi
    
    # Backup config file yang ada jika ada
    if [ -f "$CONFIG_FILE" ]; then
        local backup_file="$CONFIG_FILE.backup.$(date +%Y%m%d_%H%M%S)"
        print_verbose "Config file lama ditemukan, membuat backup ke: $backup_file"
        cp "$CONFIG_FILE" "$backup_file"
        print_verbose "Backup berhasil dibuat"
    fi
    
    print_verbose "Membuat config file baru..."
    
    # Buat config file
    cat > "$CONFIG_FILE" << EOF
tunnel: $tunnel_id
credentials-file: $CLOUDFLARED_DIR/$tunnel_id.json

ingress:
  - hostname: $hostname
    service: http://localhost:$local_port
  - service: http_status:404

# Konfigurasi tambahan untuk optimasi
originRequest:
  connectTimeout: 30s
  tlsTimeout: 30s
  tcpKeepAlive: 30s
  noHappyEyeballs: false
  keepAliveConnections: 10
  keepAliveTimeout: 90s
  httpHostHeader: $hostname

# Logging
loglevel: info
transport-loglevel: info
EOF

    local config_creation_status=$?
    
    if [ $config_creation_status -eq 0 ]; then
        print_success "Config file berhasil dibuat: $CONFIG_FILE"
        
        if [ "$VERBOSE" = true ]; then
            print_verbose "Informasi config file yang dibuat:"
            print_verbose "  - Path: $CONFIG_FILE"
            print_verbose "  - Ukuran: $(du -h "$CONFIG_FILE" | cut -f1)"
            print_verbose "  - Permission: $(ls -l "$CONFIG_FILE" | awk '{print $1}')"
            print_verbose "  - Owner: $(ls -l "$CONFIG_FILE" | awk '{print $3":"$4}')"
            print_verbose ""
            print_verbose "Isi config file:"
            print_verbose "=================="
            while IFS= read -r line; do
                print_verbose "$line"
            done < "$CONFIG_FILE"
            print_verbose "=================="
        fi
        
        # Validasi config file
        print_verbose "Memvalidasi config file yang dibuat..."
        if cloudflared tunnel --config "$CONFIG_FILE" validate 2>/dev/null; then
            print_verbose "✓ Config file valid"
        else
            print_verbose "⚠ Config file mungkin memiliki masalah (gunakan 'cloudflared tunnel --config $CONFIG_FILE validate' untuk detail)"
        fi
        
    else
        print_error "Gagal membuat config file"
        exit 1
    fi
}

# Fungsi untuk menampilkan informasi config yang sudah ada
show_existing_config() {
    local tunnel_name="$1"
    local tunnel_id=$(get_tunnel_id "$tunnel_name")
    local hostname=$(grep -A 10 "ingress:" "$CONFIG_FILE" | grep "hostname:" | head -1 | cut -d' ' -f4)
    local service=$(grep -A 10 "ingress:" "$CONFIG_FILE" | grep "service:" | head -1 | cut -d' ' -f4)
    
    print_warning "Konfigurasi tunnel '$tunnel_name' sudah ada!"
    echo ""
    echo "Detail konfigurasi:"
    echo "  Tunnel ID: $tunnel_id"
    echo "  Hostname: $hostname"
    echo "  Service: $service"
    echo "  Config file: $CONFIG_FILE"
    echo ""
    echo "Untuk melihat config lengkap: cat $CONFIG_FILE"
    echo "Untuk menjalankan tunnel: cloudflared tunnel run $tunnel_name"
    echo "Untuk mengupdate config: hapus file $CONFIG_FILE dan jalankan script ini lagi"
}

# Main function
main() {
    echo "🚀 Cloudflare Tunnel Auto Configuration"
    echo "======================================"
    
    # Cek prasyarat
    check_cloudflared
    check_cloudflared_auth
    
    # Tampilkan menu tunnel
    while true; do
        if show_tunnel_menu; then
            break
        fi
        # echo ""
        print_warning "Silakan pilih lagi..."
    done
    
    # Cek apakah config sudah ada untuk tunnel ini
    if config_exists_for_tunnel "$SELECTED_TUNNEL_NAME"; then
        show_existing_config "$SELECTED_TUNNEL_NAME"
        exit 0
    fi
    
    # Input konfigurasi
    echo ""
    print_info "Mengkonfigurasi tunnel: $SELECTED_TUNNEL_NAME"
    echo ""
    
    # Input domain utama
    while true; do
        BASE_DOMAIN=$(read_with_default "Masukkan domain utama" "$DEFAULT_DOMAIN")
        if validate_domain "$BASE_DOMAIN"; then
            break
        fi
    done
    
    # Tampilkan menu subdomain
    while true; do
        if show_subdomain_menu "$SELECTED_TUNNEL_NAME" "$BASE_DOMAIN"; then
            break
        fi
        echo ""
        print_warning "Silakan pilih lagi..."
    done
    
    # Input port lokal
    while true; do
        LOCAL_PORT=$(read_with_default "Masukkan port lokal aplikasi" "$DEFAULT_LOCAL_PORT")
        if validate_port "$LOCAL_PORT"; then
            break
        fi
    done
    
    echo ""
    echo "Konfigurasi yang akan dibuat:"
    echo "  Nama tunnel: $SELECTED_TUNNEL_NAME"
    echo "  Tunnel ID: ${SELECTED_TUNNEL_ID:-'(akan dibuat)'}"
    echo "  Hostname: $SELECTED_HOSTNAME"
    echo "  Local service: http://localhost:$LOCAL_PORT"
    echo "  Mode subdomain: $SUBDOMAIN_MODE"
    echo ""
    
    read -p "Lanjutkan? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Dibatalkan."
        exit 0
    fi
    
    # Proses berdasarkan mode
    if [ "$TUNNEL_MODE" = "create" ]; then
        # Buat tunnel baru
        TUNNEL_ID=$(create_tunnel "$SELECTED_TUNNEL_NAME")
    else
        # Gunakan tunnel yang sudah ada
        TUNNEL_ID="$SELECTED_TUNNEL_ID"
        print_info "Menggunakan tunnel yang sudah ada: $SELECTED_TUNNEL_NAME (ID: $TUNNEL_ID)"
    fi
    
    # Setup DNS route (hanya jika subdomain baru atau manual)
    if [ "$SUBDOMAIN_MODE" = "create" ] || [ "$SUBDOMAIN_MODE" = "manual" ]; then
        setup_dns_route "$SELECTED_TUNNEL_NAME" "$SELECTED_HOSTNAME"
    else
        print_info "Menggunakan DNS route yang sudah ada untuk: $SELECTED_HOSTNAME"
    fi
    
    # Buat config file
    create_config_file "$TUNNEL_ID" "$SELECTED_HOSTNAME" "$LOCAL_PORT"
    
    echo ""
    print_success "Konfigurasi tunnel berhasil dibuat!"
    echo ""
    echo "Langkah selanjutnya:"
    echo "1. Test tunnel: cloudflared tunnel --config $CONFIG_FILE run $SELECTED_TUNNEL_NAME"
    echo "2. Setup systemd service (opsional):"
    echo "   sudo tee /etc/systemd/system/cloudflared.service > /dev/null << EOF"
    echo "[Unit]"
    echo "Description=Cloudflare Tunnel"
    echo "After=network.target"
    echo ""
    echo "[Service]"
    echo "Type=simple"
    echo "User=$(whoami)"
    echo "ExecStart=/usr/local/bin/cloudflared tunnel --config $CONFIG_FILE run $SELECTED_TUNNEL_NAME"
    echo "Restart=on-failure"
    echo "RestartSec=10"
    echo "KillMode=mixed"
    echo ""
    echo "[Install]"

}

main
