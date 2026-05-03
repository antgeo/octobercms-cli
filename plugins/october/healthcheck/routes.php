<?php

use Illuminate\Support\Facades\Route;
use Illuminate\Support\Facades\DB;

Route::get('/up', function () {
    $checks = [];
    $allPassed = true;

    // PHP-FPM is responsive by definition — this code is executing.
    $checks['php_fpm'] = 'ok';

    // Database connectivity check.
    try {
        DB::connection()->getPdo();
        $checks['database'] = 'ok';
    } catch (\Throwable $e) {
        $checks['database'] = 'error: ' . $e->getMessage();
        $allPassed = false;
    }

    // Migrations table check — confirms october:migrate has run at least once.
    if ($checks['database'] === 'ok') {
        try {
            $exists = DB::getSchemaBuilder()->hasTable('migrations');
            $checks['migrations_table'] = $exists ? 'ok' : 'missing';
            if (! $exists) {
                $allPassed = false;
            }
        } catch (\Throwable $e) {
            $checks['migrations_table'] = 'error: ' . $e->getMessage();
            $allPassed = false;
        }
    } else {
        $checks['migrations_table'] = 'skipped';
    }

    return response()->json([
        'status' => $allPassed ? 'ok' : 'error',
        'checks' => $checks,
    ], $allPassed ? 200 : 503);
});
