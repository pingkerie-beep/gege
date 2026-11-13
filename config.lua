getgenv().GENHUB_GROWBLOX={
    ---------------------------------------------------------------------------
    -- CONFIG PER USERNAME
    -- Nama key = username Roblox (huruf besar/kecil, spasi, _ dan - tidak berpengaruh).
    -- Semua isi bersifat opsional; yang tidak ditulis memakai nilai default.
    -- Semua pengaturan dibaca dari tabel ini, bukan dari file .json.
    ---------------------------------------------------------------------------
    users={
        ["username"]={
            -- ===== MODE UTAMA =====
            mode="farm",            -- apa yang dijalankan akun ini:
                                    --   "farm"    = tanam + panen otomatis
                                    --   "pnb"     = Punch & Break block terus-menerus
                                    --   "harvest" = panen saja, tanpa menanam
                                    --   "idle"    = tidak menjalankan apa-apa
            -- ===== FARM (dipakai kalau mode="farm") =====
            target=954,               -- ID block yang di-farm (ID seed = ID block + 1, otomatis)
            farmWorld="farmname",  -- nama world tempat farm; script kembali ke sini kalau keluar world
            saveWorld="savename",           -- world tempat menyimpan WL & seed. "" = disimpan di farmWorld
            depositId=20,           -- patokan tempat setor WL & seed:
                                    --   1422     = Display Box
                                    --   ID lain  = Ground Drop (barang dijatuhkan di dekat block ID tersebut)
            buyWL=true,            -- true = beli World Lock otomatis
            dontPlant=false,        -- true = hanya panen, tidak menanam ulang (butuh Level 10+ dan saveWorld terisi,
                                    --        kalau syarat tidak terpenuhi otomatis kembali ke farm normal)
            randomPnb=true,        -- true = PNB di world random

            -- ===== PNB (dipakai kalau mode="pnb") =====
            pnbId=nil,              -- ID block yang di-PNB, contoh: pnbId=4
            pnbDrop=true,           -- true = buang (drop) seed saat sudah mencapai 200

            -- ===== HARVEST (dipakai kalau mode="harvest") =====
            harvestBlock=nil,       -- ID block yang dipanen, contoh: harvestBlock=2
            harvestFarmWorld="",    -- world tempat panen
            harvestSaveWorld="",    -- world tempat menyimpan hasil panen ("" = di world panen)
            harvestDepositId=1422,  -- patokan setor hasil panen (aturan sama seperti depositId)
            harvestDropSeed=false,  -- true = seed hasil panen ikut didrop/disetor
            -- ===== PNB & PENGAMBILAN DROP =====
            hits=2,                 -- jumlah pukulan per putaran PNB
            delay=0.06,             -- jeda antar aksi dalam detik (makin kecil = makin cepat, makin berisiko)
            range=3,                -- jarak (tile) drop yang diambil; hanya filter lokal, jarak server tidak berubah
            collectFilter="ALL",    -- drop yang diambil: "ALL" = semua, atau daftar ID dipisah koma, contoh "2,3,4"
            -- ===== EFEK & FPS =====
            sounds=false,           -- true = suara PNB aktif
            hands=false,            -- true = animasi tangan PNB aktif
            blockFx=false,          -- true = efek pecahnya block aktif
            lowGraphics=true,       -- true = grafis diturunkan (bayangan & partikel dimatikan, tidak ada yang dihapus)
            render3dOff=true,       -- true = render 3D dimatikan, GUI game tetap tampil (paling hemat FPS)
            hideUsername=false,     -- true = username disembunyikan di layar status
        },
    },
}

loadstring(game:HttpGet("https://urlfunction"))()
