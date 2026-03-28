<?php
header("Content-Type: application/json");
header("Access-Control-Allow-Origin: *");

$api_key = "sk-89c220f97a2f4b78af3358e534f8b72e";
$url = "https://grsai.dakka.com.cn/v1/draw/completions";

$input = json_decode(file_get_contents("php://input"), true);
$prompt = $input['prompt'] ?? '';
$size = $input['size'] ?? '1:1';

$data = [
    "model" => "sora-image",
    "prompt" => $prompt,
    "size" => $size,
    "variants" => 1,
    "urls" => [],
    "webHook" => "",
    "shutProgress" => false
];

$opts = [
    'http' => [
        'method'  => 'POST',
        'header'  => "Content-Type: application/json\r\nAuthorization: Bearer {$api_key}\r\n",
        'content' => json_encode($data)
    ]
];

$response = file_get_contents($url, false, stream_context_create($opts));
echo $response;
?>
