<?php

function mixedWorkload(): int {
    $records = [];
    for ($i = 0; $i < 6000; $i++) {
        $records[] = [
            'id' => $i,
            'slug' => sprintf('record-%04d', $i),
            'name' => str_repeat(chr(65 + ($i % 26)), 8),
            'meta' => ['left' => $i % 97, 'right' => ($i * 7) % 101],
        ];
    }

    for ($round = 0; $round < 12; $round++) {
        $json = json_encode($records, JSON_THROW_ON_ERROR);
        $decoded = json_decode($json, true, 512, JSON_THROW_ON_ERROR);
        usort($decoded, static fn(array $a, array $b): int => $a['meta']['right'] <=> $b['meta']['right']);

        $bucket = [];
        foreach ($decoded as $row) {
            $key = preg_replace('/[^a-z0-9]+/i', '-', strtolower($row['slug']));
            $bucket[$key] = hash('sha256', serialize($row), false);
        }

        arsort($bucket);
        $records = [];
        $slice = array_slice($bucket, 0, 1200, true);
        foreach ($slice as $key => $digest) {
            $records[] = [
                'slug' => $key,
                'digest' => $digest,
                'parts' => array_reverse(explode('-', $key)),
            ];
        }
    }

    return count($records);
}

class A {
    public int $x = 0;
    public string $s = '';
}

class B extends A {
    public float $f = 0.0;
}

function diverseWork(int $i): array {
    $a = new A();
    $a->x = $i;
    $a->s = 'str' . $i;
    $b = new B();
    $b->f = $i * 1.5;
    $b->x = $i + 1;
    $arr = [$a, $b, $i, 'key' => $a->s];
    $arr[] = $b->f;
    unset($arr['key']);
    $result = array_map(fn($v) => is_object($v) ? get_class($v) : (string) $v, $arr);
    $x = match (true) {
        $i % 3 === 0 => 'fizz',
        $i % 5 === 0 => 'buzz',
        default => (string) $i,
    };
    return [...$result, $x];
}

function diverseWorkload(): int {
    $count = 0;
    for ($i = 0; $i < 400_000; $i++) {
        $count += count(diverseWork($i));
    }
    return $count;
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
    for ($i = 0; $i < 300; $i++) {
        $tree = buildTree(12);
        $total += $tree->sum();
        $total += $tree->depth();
    }
    return $total;
}

$result = 0;
$result += mixedWorkload();
$result += diverseWorkload();
$result += oopWorkload();

echo $result, PHP_EOL;
