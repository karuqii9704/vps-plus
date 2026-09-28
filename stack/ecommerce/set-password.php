<?php
/**
 * Sets a user's password (and marks the e-mail verified).
 *
 * Usage (from the box):
 *   docker run --rm --network host --user 33:33 \
 *     -v /srv/repos/ecommerce:/srv/repos/ecommerce \
 *     -v /srv/vps-plus/stack/ecommerce:/opt/demo:ro \
 *     -w /srv/repos/ecommerce vpsplus-ecommerce:latest \
 *     php /opt/demo/set-password.php <email> <new-password>
 */

require '/srv/repos/ecommerce/vendor/autoload.php';

$app = require_once '/srv/repos/ecommerce/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

$email = $argv[1] ?? null;
$password = $argv[2] ?? null;

if (! $email || ! $password) {
    fwrite(STDERR, "usage: set-password.php <email> <password>\n");
    exit(1);
}

$user = App\Models\User::query()->where('email', $email)->firstOrFail();
$user->password = Illuminate\Support\Facades\Hash::make($password);
$user->email_verified_at = $user->email_verified_at ?? now();
$user->save();

echo "password updated for {$user->email} (id {$user->id}, roles: ".$user->getRoleNames()->implode(',').")\n";
