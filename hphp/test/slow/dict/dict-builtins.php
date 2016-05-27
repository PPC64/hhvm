<?hh // strict
// Copyright 2004-present Facebook. All Rights Reserved.

function sum($carr, $item) {
  return $carr + $item;
}

function main($v) {
  echo "Testing: ";
  var_dump($v);

  echo "array_count_values: ";
  var_dump(array_count_values($v));

  echo "array_pad (after): ";
  var_dump(array_pad($v, 10, "pad"));
  echo "array_pad (before): ";
  var_dump(array_pad($v, -10, "pad"));
  echo "array_pad (just one): ";
  var_dump(array_pad($v, 1, "pad"));

  echo "array_pop: ";
  $copy_v = $v;
  var_dump(array_pop($copy_v));
  var_dump($copy_v);

  echo "array_product: ";
  var_dump(array_product($v));

  echo "array_push: ";
  $copy_v = $v;
  var_dump(array_push($copy_v, "pushed1", "pushed2", "pushed3"));
  var_dump($copy_v);

  echo "array_reduce: ";
  var_dump(array_reduce($v, "sum", 0));

  echo "array_reverse: ";
  var_dump(array_reverse($v));

  echo "array_search (2): ";
  var_dump(array_search(2, $v));
  echo "array_search (\"not-found\"): ";
  var_dump(array_search("not-found", $v));
  echo "array_search (false): ";
  var_dump(array_search(false, $v));
  echo "array_search (\"2\"): ";
  var_dump(array_search("2", $v));

  echo "array_shift: ";
  $copy_v = $v;
  var_dump(array_shift($copy_v));
  var_dump($copy_v);

  echo "array_sum: ";
  var_dump(array_sum($v));

  echo "array_unshift: ";
  $copy_v = $v;
  var_dump(array_unshift($copy_v, "prepend1", "prepend2"));
  var_dump($copy_v);

  echo "count: ";
  var_dump(count($v));

  echo "in_array (3): ";
  var_dump(in_array(3, $v));
  echo "in_array (\"not-found\"): ";
  var_dump(in_array("not-found", $v));
  echo "in_array (false): ";
  var_dump(in_array(false, $v));
  echo "in_array (\"3\"): ";
  var_dump(in_array("3", $v));

  echo "sort: ";
  $copy_v = $v;
  var_dump(sort($copy_v));
  var_dump($copy_v);

  echo "rsort: ";
  $copy_v = $v;
  var_dump(rsort($copy_v));
  var_dump($copy_v);

  echo "asort: ";
  $copy_v = $v;
  var_dump(asort($copy_v));
  var_dump($copy_v);

  echo "arsort: ";
  $copy_v = $v;
  var_dump(arsort($copy_v));
  var_dump($copy_v);

  echo "ksort: ";
  $copy_v = $v;
  var_dump(ksort($copy_v));
  var_dump($copy_v);

  echo "krsort: ";
  $copy_v = $v;
  var_dump(krsort($copy_v));
  var_dump($copy_v);
}

function test_is_a($a) {
  echo "Testing is-a: ";
  var_dump($a);

  echo "is_array: ";
  var_dump(is_array($a));
  echo "is_dict: ";
  var_dump(is_dict($a));
}

main(dict[]);
main(dict[0 => 1, 1 => 2, 2 => 3, 3 => 4, 4 => 5]);

test_is_a(dict[]);
test_is_a(dict[0 => "value1", 1 => "value2"]);
test_is_a([]);
test_is_a(["value1", "value2"]);
test_is_a(dict[]);
test_is_a(vec["value1", "value2"]);
