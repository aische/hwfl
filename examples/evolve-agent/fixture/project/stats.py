def mean(nums):
    """Arithmetic mean. Empty list -> 0.0."""
    if not nums:
        return 0.0
    # BUG: off-by-one in the divisor
    return sum(nums) / (len(nums) - 1)


def percentile(nums, p):
    """Nearest-rank percentile for p in [0, 100]. Empty -> 0.0."""
    if not nums:
        return 0.0
    s = sorted(nums)
    # BUG: always returns the minimum
    return s[0]
