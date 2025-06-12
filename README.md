# Akses Online
> domain: akses.online
> tunnel example: randomsubdom.ain.online

## Gagasan
> Akses adalah Layanan Tunnel alternatif Cloudflared Tunnel, Ngrok, Zrok, ServerO dan sejenisnya, silahkan pilih mana yang lebih dekat dengan ekosistem bisnis anda
Dengan layanan tunnel dari Koneksi Cloud, Luncurkan aplikasi lokal ke internet hanya dalam hitungan detik — tanpa konfigurasi kompleks, cukup satu kali perintah klik.

## DEMO
### CF Tunnel (cloudflared auth) + CF Zona (API Token)
> Goals -> Integrate Akses/CF Tunnel -> Akses Client Proxy Forwarder
```bash
dev@isp:~/working_dir$ ./simulasi.sh 
=== Simulasi Interaktif Cloudflare API dengan .env Otomatis ===

🔐 Mendeteksi token dari /home/dev/.akses/.env...
✅ Token valid. Melanjutkan dengan token yang sudah ada.

📦 Mengambil daftar zona dari akun Anda...

  1) example.com

Pilih nomor zona yang ingin digunakan: 1
✅ Zona terpilih: example.com (ID: 000f46aaa89abbba038accc2f0aaddd5)

🌐 Mengambil daftar DNS record (CNAME) untuk konxc.space...

| No | FQDN                        | Tunnel (ID) / Point Name               |
|----|-----------------------------|----------------------------------------|
|  1 | srv1.example.com            | tunnel1 (c8e8deee...)                  |
|  2 | srv2.example.com            | tunnel2 (d6895009...)                  |

Pilih nomor subdomain yang ingin diperiksa: 1
✅ Subdomain terpilih: srv1.example.com → c8e8deee-ccce-bbb9-aaa4-ff3cfff8bddd.cfargotunnel.come
```

## GUIDE LINE FOR DEVELOPER
