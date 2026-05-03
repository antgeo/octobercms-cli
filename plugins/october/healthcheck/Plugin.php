<?php namespace October\Healthcheck;

use System\Classes\PluginBase;

class Plugin extends PluginBase
{
    public function pluginDetails(): array
    {
        return [
            'name'        => 'Health Check',
            'description' => 'Provides the /up endpoint for container health checks.',
            'author'      => 'OctoberCMS CLI (third-party)',
            'icon'        => 'icon-heart',
        ];
    }
}
