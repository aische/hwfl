from stats import mean, percentile


def test_mean():
    assert abs(mean([2, 4, 6]) - 4.0) < 1e-9


def test_mean_empty():
    assert mean([]) == 0.0


def test_percentile():
    xs = [10, 20, 30, 40]
    assert percentile(xs, 0) == 10
    assert percentile(xs, 100) == 40
    assert percentile(xs, 50) == 20
