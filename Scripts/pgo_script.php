<?php

function buildSeedRecords(int $count): array {
    $records = [];
    for ($i = 0; $i < $count; $i++) {
        $records[] = [
            'id' => $i,
            'slug' => sprintf('record-%04d', $i),
            'name' => str_repeat(chr(65 + ($i % 26)), 8),
            'meta' => [
                'left' => $i % 97,
                'right' => ($i * 7) % 101,
            ],
            'tags' => [
                'group-' . ($i % 8),
                'bucket-' . (($i * 3) % 11),
            ],
            'active' => ($i % 2) === 0,
        ];
    }

    return $records;
}

function compareRecords(array $left, array $right): int {
    $metaComparison = $left['meta']['right'] <=> $right['meta']['right'];
    if ($metaComparison !== 0) {
        return $metaComparison;
    }

    return $left['id'] <=> $right['id'];
}

function mixedWorkload(): int {
    $records = buildSeedRecords(6000);
    $checksum = 0;

    for ($round = 0; $round < 12; $round++) {
        $json = json_encode($records, JSON_THROW_ON_ERROR);
        $decoded = json_decode($json, true, 512, JSON_THROW_ON_ERROR);
        usort($decoded, compareRecords(...));

        $bucket = [];
        foreach ($decoded as $row) {
            $slug = preg_replace('/[^a-z0-9]+/i', '-', strtolower($row['slug']));
            $parts = array_values(array_filter(explode('-', trim($slug, '-')), 'strlen'));
            $digest = hash('sha256', serialize($row), false);
            $score = ($row['meta']['left'] * 31 + $row['meta']['right'] * 17 + strlen($row['name'])) % 1009;

            $bucket[$slug] = [
                'id' => $row['id'],
                'digest' => $digest,
                'parts' => $parts,
                'score' => $score + hexdec(substr($digest, 0, 2)),
                'active' => $row['active'],
            ];
        }

        uasort($bucket, static fn(array $left, array $right): int => $right['score'] <=> $left['score']);

        $records = [];
        foreach (array_slice($bucket, 0, 1200, true) as $slug => $row) {
            $records[] = [
                'id' => $row['id'],
                'slug' => $slug,
                'name' => substr(strtoupper(str_replace('-', '', $slug)), 0, 16),
                'meta' => [
                    'left' => strlen($slug) + count($row['parts']),
                    'right' => (hexdec(substr($row['digest'], 2, 4)) + $row['score']) % 251,
                ],
                'tags' => $row['parts'] ?: ['root'],
                'active' => $row['active'],
            ];
            $checksum += $row['score'];
        }
    }

    return $checksum + count($records);
}

class A {
    public int $x = 0;
    public string $s = '';

    public function label(): string {
        return $this->s . ':' . $this->x;
    }
}

class B extends A {
    public float $f = 0.0;

    public function label(): string {
        return parent::label() . ':' . number_format($this->f, 2, '.', '');
    }
}

function diverseWork(int $i): array {
    $a = new A();
    $a->x = $i;
    $a->s = 'str' . $i;

    $b = new B();
    $b->f = $i * 1.5;
    $b->x = $i + 1;
    $b->s = 'next' . $i;

    $values = [$a, $b, $i, 'key' => $a->s];
    $values[] = $b->f;
    unset($values['key']);

    $result = array_map(
        static fn(mixed $value): string => is_object($value) ? $value->label() : (string) $value,
        $values,
    );
    $suffix = match (true) {
        $i % 3 === 0 => 'fizz',
        $i % 5 === 0 => 'buzz',
        default => (string) $i,
    };

    return [...$result, $suffix];
}

function diverseWorkload(): int {
    $count = 0;
    for ($i = 0; $i < 250_000; $i++) {
        $count += count(diverseWork($i));
    }

    return $count;
}

function eventGenerator(int $count): Generator {
    for ($i = 0; $i < $count; $i++) {
        $path = sprintf('/api/v1/items/%d/%s', $i % 200, rawurlencode((string) (($i * 13) % 997)));

        yield [
            'id' => $i,
            'path' => $path,
            'status' => [200, 201, 204, 400, 404, 429, 500][$i % 7],
            'latency' => ($i * 37) % 1000,
        ];
    }
}

function iteratorWorkload(): int {
    $events = iterator_to_array(eventGenerator(20000), false);
    $iterator = new CallbackFilterIterator(
        new ArrayIterator($events),
        static fn(array $event): bool => $event['status'] < 500 && ($event['id'] % 3 === 0 || $event['latency'] < 250),
    );

    $total = 0;
    foreach (new LimitIterator($iterator, 0, 6000) as $event) {
        $query = http_build_query([
            'id' => $event['id'],
            'path' => $event['path'],
            'status' => $event['status'],
        ]);
        parse_str($query, $parsed);

        $parts = explode('/', trim((string) $parsed['path'], '/'));
        $total += (int) $parsed['id'] + (int) $parsed['status'] + count($parts) + substr_count($event['path'], '/');
    }

    return $total;
}

function streamWorkload(): int {
    $handle = fopen('php://temp/maxmemory:1048576', 'w+');
    if ($handle === false) {
        return 0;
    }

    for ($i = 0; $i < 4000; $i++) {
        fputcsv(
            $handle,
            [
                $i,
                sprintf('package-%04d', $i),
                ($i * 11) % 97,
                ($i % 2) === 0 ? 'stable' : 'testing',
            ],
            ',',
            '"',
            '\\',
        );
    }

    rewind($handle);

    $total = 0;
    while (($row = fgetcsv($handle, null, ',', '"', '\\')) !== false) {
        [$id, $slug, $score, $channel] = $row;
        $payload = [
            'id' => (int) $id,
            'slug' => $slug,
            'score' => (int) $score,
            'channel' => $channel,
        ];
        $encoded = base64_encode(json_encode($payload, JSON_THROW_ON_ERROR));
        $decoded = json_decode(base64_decode($encoded, true), true, 512, JSON_THROW_ON_ERROR);
        $total += $decoded['id'] + $decoded['score'] + strlen($decoded['slug']) + strlen($decoded['channel']);
    }

    fclose($handle);

    return $total;
}

function dateWorkload(): int {
    $base = new DateTimeImmutable('2026-01-01 00:00:00', new DateTimeZone('UTC'));
    $timezones = [
        new DateTimeZone('UTC'),
        new DateTimeZone('Asia/Kolkata'),
        new DateTimeZone('America/New_York'),
    ];

    $total = 0;
    for ($i = 0; $i < 4000; $i++) {
        $timestamp = $base
            ->add(new DateInterval('PT' . ($i % 1440) . 'M'))
            ->modify(($i % 11) . ' days');
        $formatted = $timestamp
            ->setTimezone($timezones[$i % count($timezones)])
            ->format(DateTimeInterface::ATOM);
        $total += strlen($formatted) + (int) $timestamp->format('z');
    }

    return $total;
}

#[Attribute(Attribute::TARGET_CLASS)]
final class PgoServiceTag {
    public function __construct(
        public readonly string $name,
        public readonly bool $shared = true,
    ) {}
}

#[PgoServiceTag('normalizer')]
final class PgoPayloadNormalizer {
    /**
     * @param array<string, mixed> $payload
     * @return array<string, mixed>
     */
    public function normalize(array $payload): array {
        $payload['slug'] = preg_replace('/[^a-z0-9]+/i', '-', strtolower((string) $payload['slug'])) ?? '';
        $payload['title'] = trim((string) $payload['title']);
        $payload['active'] = (bool) ($payload['active'] ?? false);

        return $payload;
    }
}

#[PgoServiceTag('hasher')]
final class PgoHasher {
    /**
     * @param array<string, mixed> $payload
     */
    public function digest(array $payload): string {
        return hash('sha256', json_encode($payload, JSON_THROW_ON_ERROR));
    }
}

#[PgoServiceTag('router', false)]
final class PgoRouter {
    /**
     * @param array<string, mixed> $request
     * @return array{handler:string,params:array<string, string>}
     */
    public function match(array $request): array {
        $path = trim((string) $request['path'], '/');
        $parts = explode('/', $path);

        return [
            'handler' => $parts[0] === 'api' ? 'api.show' : 'web.index',
            'params' => [
                'section' => $parts[0] ?? 'home',
                'id' => $parts[2] ?? '0',
            ],
        ];
    }
}

final class PgoContainer {
    /**
     * @var array<class-string, object>
     */
    private array $instances = [];

    /**
     * @template T of object
     * @param class-string<T> $id
     * @return T
     */
    public function get(string $id): object {
        if (isset($this->instances[$id])) {
            return $this->instances[$id];
        }

        $reflection = new ReflectionClass($id);
        $attributes = $reflection->getAttributes(PgoServiceTag::class);
        $shared = $attributes === [] || ($attributes[0]->newInstance())->shared;
        $instance = $reflection->newInstance();

        if ($shared) {
            $this->instances[$id] = $instance;
        }

        return $instance;
    }
}

/**
 * @return list<array<string, mixed>>
 */
function buildRequests(int $count): array {
    $requests = [];
    for ($i = 0; $i < $count; $i++) {
        $requests[] = [
            'path' => sprintf('/api/posts/%d/%s', $i % 500, rawurlencode('Post ' . $i)),
            'title' => '  Article ' . $i . '  ',
            'slug' => sprintf('Article %d %d', $i, $i % 7),
            'active' => ($i % 2) === 0,
            'meta' => [
                'group' => $i % 9,
                'bucket' => ($i * 5) % 13,
            ],
        ];
    }

    return $requests;
}

function frameworkWorkload(): int {
    $container = new PgoContainer();
    $checksum = 0;

    for ($round = 0; $round < 30; $round++) {
        $requests = buildRequests(1800);
        /** @var PgoPayloadNormalizer $normalizer */
        $normalizer = $container->get(PgoPayloadNormalizer::class);
        /** @var PgoHasher $hasher */
        $hasher = $container->get(PgoHasher::class);
        /** @var PgoRouter $router */
        $router = $container->get(PgoRouter::class);

        foreach ($requests as $request) {
            $matched = $router->match($request);
            $normalized = $normalizer->normalize($request + $matched['params']);
            $digest = $hasher->digest($normalized + ['handler' => $matched['handler']]);
            $checksum += strlen($digest) + (int) ($normalized['active'] ? 11 : 3);
        }
    }

    return $checksum;
}

function reflectionWorkload(): int {
    $classes = [PgoPayloadNormalizer::class, PgoHasher::class, PgoRouter::class];
    $checksum = 0;

    for ($round = 0; $round < 1200; $round++) {
        foreach ($classes as $class) {
            $reflection = new ReflectionClass($class);
            foreach ($reflection->getMethods() as $method) {
                $checksum += strlen($method->getName()) + count($method->getParameters());
            }
            foreach ($reflection->getAttributes(PgoServiceTag::class) as $attribute) {
                $instance = $attribute->newInstance();
                $checksum += strlen($instance->name) + (int) $instance->shared;
            }
        }
    }

    return $checksum;
}

class Node {
    public function __construct(
        public readonly string $name,
        public readonly int $value,
        public readonly ?Node $left = null,
        public readonly ?Node $right = null,
    ) {}

    public function sum(): int {
        return $this->value
            + ($this->left?->sum() ?? 0)
            + ($this->right?->sum() ?? 0);
    }

    public function depth(): int {
        return 1 + max(
            $this->left?->depth() ?? 0,
            $this->right?->depth() ?? 0,
        );
    }
}

function buildTree(int $depth, int $id = 0): Node {
    if ($depth === 0) {
        return new Node("leaf-$id", $id);
    }

    return new Node(
        "node-$id",
        $id,
        buildTree($depth - 1, 2 * $id + 1),
        buildTree($depth - 1, 2 * $id + 2),
    );
}

function oopWorkload(): int {
    $total = 0;
    for ($i = 0; $i < 250; $i++) {
        $tree = buildTree(12);
        $total += $tree->sum();
        $total += $tree->depth();
    }

    return $total;
}

$result = 0;
$result += mixedWorkload();
$result += diverseWorkload();
$result += iteratorWorkload();
$result += streamWorkload();
$result += dateWorkload();
$result += frameworkWorkload();
$result += reflectionWorkload();
$result += oopWorkload();

echo $result, PHP_EOL;
