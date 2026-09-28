<?php
/**
 * Demo catalogue for the ecommerce subdomain (ecommerce.plusthe.site).
 *
 * Runs OUTSIDE the framework: boots Laravel, then creates a small but
 * believable Indonesian catalogue (categories + products + images) so the
 * storefront is not empty on first visit. Idempotent — safe to re-run.
 *
 * Usage (from the box):
 *   docker run --rm --network host --user 33:33 \
 *     -v /srv/repos/ecommerce:/srv/repos/ecommerce \
 *     -v /srv/vps-plus/stack/ecommerce:/opt/demo:ro \
 *     -w /srv/repos/ecommerce vpsplus-ecommerce:latest \
 *     php /opt/demo/demo-data.php
 */

require '/srv/repos/ecommerce/vendor/autoload.php';

$app = require_once '/srv/repos/ecommerce/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

use App\Models\Product\Product;
use App\Models\Product\ProductCategory;
use App\Models\Product\ProductFlat;
use App\Models\Shop\Shop;

$shop = Shop::query()->orderBy('id')->first();
if (! $shop) {
    fwrite(STDERR, "no shop found — run db:seed first\n");
    exit(1);
}
echo "shop: {$shop->id} {$shop->name}\n";

$categories = [
    'Elektronik' => 'Gadget, audio, dan aksesori elektronik pilihan.',
    'Fashion Pria' => 'Kemeja, kaos, dan sepatu untuk pria.',
    'Fashion Wanita' => 'Dress, blouse, dan tas untuk wanita.',
    'Rumah Tangga' => 'Peralatan rumah, dapur, dan dekorasi.',
];

$categoryModels = [];
foreach ($categories as $name => $description) {
    $category = ProductCategory::query()->firstOrCreate(
        ['name' => $name],
        ['slug' => Illuminate\Support\Str::slug($name), 'description' => $description, 'is_featured' => true],
    );

    if (! $category->hasMedia('image')) {
        try {
            $category->addMediaFromUrl('https://picsum.photos/seed/cat-'.md5($name).'/800/600')
                ->toMediaCollection('image');
            echo "  media: category {$name}\n";
        } catch (Throwable $e) {
            echo "  ! media failed for category {$name}: {$e->getMessage()}\n";
        }
    }
    $categoryModels[$name] = $category;
}

$products = [
    // name, category, price, weight(g), stock, description
    ['Headphone Bluetooth Pro', 'Elektronik', 1250000, 300, 25, 'Headphone over-ear dengan active noise cancelling dan baterai 40 jam.'],
    ['Smartwatch Sport S2', 'Elektronik', 899000, 60, 40, 'Jam pintar dengan pemantau detak jantung, GPS, dan tahan air 5ATM.'],
    ['Speaker Portabel Bass+', 'Elektronik', 475000, 800, 60, 'Speaker Bluetooth tahan air dengan bass mendalam, cocok untuk outdoor.'],
    ['Powerbank 20.000 mAh', 'Elektronik', 289000, 450, 120, 'Powerbank fast charging 22.5W dengan dua port USB dan satu USB-C.'],
    ['Kemeja Linen Oxford', 'Fashion Pria', 249000, 250, 80, 'Kemeja linen premium potongan slim fit, adem dan tidak mudah kusut.'],
    ['Sneakers Canvas Classic', 'Fashion Pria', 379000, 700, 55, 'Sepatu kanvas klasik dengan sol karet anti-slip, nyaman dipakai harian.'],
    ['Kaos Katun Combed 30s', 'Fashion Pria', 99000, 180, 200, 'Kaos katun combed 30s jahitan rapi, tersedia beberapa pilihan warna.'],
    ['Dress Midi Elegan', 'Fashion Wanita', 429000, 300, 45, 'Dress midi bahan sifon dengan aksen lipit, cocok untuk acara semi formal.'],
    ['Tas Kulit Sintetis Avery', 'Fashion Wanita', 359000, 500, 50, 'Tas selempang kulit sintetis dengan kompartemen lapis dan tali adjustable.'],
    ['Blouse Satin Lengan Panjang', 'Fashion Wanita', 219000, 200, 70, 'Blouse satin jatuh dengan kerah shanghai, adem untuk kerja sehari-hari.'],
    ['Set Panci Anti Lengket', 'Rumah Tangga', 545000, 2500, 30, 'Set 5 panci anti lengket dengan tutup kaca, aman untuk semua kompor.'],
    ['Lampu Meja LED Minimalis', 'Rumah Tangga', 159000, 600, 90, 'Lampu meja LED tiga tingkat kecerahan dengan port USB charger.'],
];

foreach ($products as [$name, $categoryName, $price, $weight, $stock, $description]) {
    $slug = Illuminate\Support\Str::slug($name);

    $product = Product::query()->firstOrCreate(
        ['slug' => $slug],
        [
            'product_category_id' => $categoryModels[$categoryName]->id,
            'shop_id' => $shop->id,
            'type' => 'simple',
            'name' => $name,
            'description' => $description,
            'price' => $price,
            'weight' => $weight,
            'length' => 20,
            'width' => 15,
            'height' => 10,
            'stock' => $stock,
            'rating' => 4.5,
            'total_reviews' => 12,
            'total_sales' => 34,
            'is_unlimited_stock' => false,
            'status' => true,
        ],
    );

    $flat = ProductFlat::query()->firstOrCreate(
        ['product_id' => $product->id],
        [
            'shop_id' => $shop->id,
            'name' => $name,
            'description' => $description,
            'price' => $price,
            'weight' => $weight,
            'length' => 20,
            'width' => 15,
            'height' => 10,
            'stock' => $stock,
            'rating' => 4.5,
            'total_reviews' => 12,
            'total_sales' => 34,
            'is_unlimited_stock' => false,
            'status' => true,
        ],
    );

    if (! $flat->hasMedia('image_slot_0')) {
        try {
            $flat->addMediaFromUrl('https://picsum.photos/seed/'.substr(md5($slug), 0, 10).'/900/900')
                ->toMediaCollection('image_slot_0');
            echo "  media: {$name}\n";
        } catch (Throwable $e) {
            echo "  ! media failed for {$name}: {$e->getMessage()}\n";
        }
    }

    echo "product: {$product->id} {$name}\n";
}

echo "\nDONE — categories: ".ProductCategory::count().", products: ".Product::count().", media: ".\Spatie\MediaLibrary\MediaCollections\Models\Media::count()."\n";
