# This file contains the routines used by grammar.coffee, to do simple constant-folding.
# It is motivated by the extension to use Scheme numbers. I decided, rather than extend
# the lexer to recognize ratios and complex numbers, that I would add constant-folding
# to turn, for example, 17 / 3 into a single Scheme number constant. The constant folder
# does not use the Scheme number library, so it does not handle the full range of Scheme
# numbers. Some will be left to be computed at run time. Constant folding will always be
# done, in a way such that it will still work and be useful even if the Scheme number
# option is not on in the compiler.

COMPLEX = ///^([+-]?)
 (\d+\/\d+   |                  # ratio
  \d*\.?\d+ (?:e[+-]?\d+)?)     # decimal
 (i |
  ([+-])
  (\d+\/\d+   |                 # ratio
   \d*\.?\d+ (?:e[+-]?\d+)?)i)? # decimal
$///i

RATIONAL = ///^ (\d+) (?:\/(\d+))? $///

complexParts = (string) ->
  parts = COMPLEX.exec(string)
  if parts?
    imagPart = parts[3]
    initialSign = parts[1] or '+'
    if not imagPart?
      [initialSign, parts[2], '+', '0']
    else if /^i$/i.test(imagPart)
      ['+', '0', initialSign, parts[2]]
    else
      [initialSign, parts[2], parts[4], parts[5]]

rationalParts = (string) ->
  parts = RATIONAL.exec(string)
  if parts
    [parts[1], parts[2] or '1']

realPartsValue = (sign, string, rationalParts) ->
  value = if rationalParts?
            +rationalParts[0] / +rationalParts[1]
          else
            +string
  value = -value if sign == '-'
  value

# Anything this big might have been rounded.
limitExact = 2 ** 53

exactAdd = (aSign, a, bSign, b) ->
  if a? and b?
    a = +a
    b = +b
    a = -a if aSign == '-'
    b = -b if bSign == '-'
    result = a + b
    if Math.abs(result) < limitExact
      result

exactMul = (a, b) ->
  if a? and b?
    result = +a * +b
    if Math.abs(result) < limitExact
      result

gcd = (a, b) ->
  [a, b] = [b, a %% b] until b == 0
  a

# Javascript does not distinguish 1 from 1.0, but we will use
# the .0 to distinguish exact from inexact.
canonicalizeInexact = (x) ->
  xString = x.toString()
  if /[.eE]|^[^\d]+$/.test(xString) then xString else "#{xString}.0"    

canonicalizeRational = (numerator, denominator) ->
  factor = gcd(numerator, denominator)
  numerator = numerator / factor
  denominator = denominator / factor
  if denominator == 1
    numerator.toString()
  else
    # numerator may be signed. That's fine.
    "#{numerator}/#{denominator}"

canonicalizeExactComplex = (real, imag) ->
  # Assumes that both parts are exact.
  if imag == '0'
    real
  else
    real = '' if real == '0'
    imagSign = if real != '' and /^-/.test(imag) then '' else '+'
    "#{real}#{imagSign}#{imag}i"

rationalPartsAdd = (aSign, a, bSign, b) ->
  denominator = exactMul(a[1], b[1])
  if denominator?
    numerator = exactAdd(aSign, exactMul(a[0], b[1]), bSign, exactMul(b[0], a[1]))
    if numerator?
      canonicalizeRational(numerator, denominator)

flipSignNeeded = (sign) ->
  if sign == '-' then '+' else '-'

flipSign = (sign) ->
  if sign == '-' then '' else '-'

exports.negate = (value) ->
  parts = complexParts(value)
  if parts[3] == '0'
     if parts[0] == '-'
        parts[1]
     else
        "-#{parts[1]}"
  else
     if parts[1] == '0'
        "#{flipSign(parts[2])}#{parts[3]}i"
     else
        "#{flipSign(parts[0])}#{parts[1]}#{flipSignNeeded(parts[2])}#{parts[3]}i"

addSub = (value1, value2, operation) ->
  parts1 = complexParts(value1)
  parts2 = complexParts(value2)
  rationalParts1real = rationalParts(parts1[1])
  rationalParts1imag = rationalParts(parts1[3])
  rationalParts2real = rationalParts(parts2[1])
  rationalParts2imag = rationalParts(parts2[3])
  if rationalParts1real and rationalParts1imag and
     rationalParts2real and rationalParts2imag
    flipSignMaybe = (sign) ->
      if operation == '-' then flipSign(sign) else sign
    real = rationalPartsAdd(parts1[0], rationalParts1real,
                            flipSignMaybe(parts2[0]), rationalParts2real)
    imag = rationalPartsAdd(parts1[2], rationalParts1imag,
                            flipSignMaybe(parts2[2]), rationalParts2imag)
    if real? and imag?
      return canonicalizeExactComplex(real, imag)
    # If we can't do it at compile time, leave it for run time.
  else
    # Use native arithmetic if anything is floating-point.
    addSubNative = (a, b) ->
      if operation == '-' then a - b else a + b
    real = addSubNative(realPartsValue(parts1[0], parts1[1], rationalParts1real),
                        realPartsValue(parts2[0], parts2[1], rationalParts2real))
    if parts1[3] == '0' and parts2[3] == '0'
      canonicalizeInexact real
    else
      imag = addSubNative(realPartsValue(parts1[2], parts1[3], rationalParts1imag),
                          realPartsValue(parts2[2], parts2[3], rationalParts2imag))
      imagSign = if imag < 0 then '' else '+'
      "#{canonicalizeInexact(real)}#{imagSign}#{canonicalizeInexact(imag)}i"

IS_STRING = /^['"]/

exports.add = (value1, value2) ->
  if IS_STRING.test(value1)
    if IS_STRING.test(value2)
      # Only handle the case when both are strings, here.
      # When one is a number and one is a string, then the
      # string will be converted to a number. That conversion might differ
      # depending on whether we are using Scheme numbers or not.
      # With Scheme numbers, "1" and "1.0" will differ.
      # With Javascript numbers, they will not.
      string = eval(value1) + eval(value2)
      # Turn this back into a string literal.
      # Escape the newlines.
      string = string.replace(/\n/g, '\\n')
      if '"' in string
        if "'" in string
          "\"#{string.replace /"/g, '\\"'}\""
        else
          "'#{string}'"
      else
        "\"#{string}\""
  else if !IS_STRING.test(value2)
    addSub(value1, value2, '+')

exports.sub = (value1, value2) -> addSub(value1, value2, '-')

rationalReduce = (num, den) ->
  # Make sure num and den are exact, with Javascript numbers.
  if num? and den? and num < 2**53 and 0 < den < 2**53
    canonicalizeRational(num, den)

# Signed integer or ratio.
SIGNED_RATIONAL = ///^ ([+-]?) (\d+) (\/(\d+))? (i?) $///

signedRationalParts = (string) ->
 match = SIGNED_RATIONAL.exec(string)
 [match[1] != '-',   # positive
  +match[2],         # numerator
  +(match[4] or 1),  # denominator
  match[5] != '']    # imaginary

exports.div = (value1, value2) ->
  if SIGNED_RATIONAL.test(value1) and SIGNED_RATIONAL.test(value2)
    [aPositive, aNum, aDen, aImag] = signedRationalParts(value1)
    [bPositive, bNum, bDen, bImag] = signedRationalParts(value2)
    positive = aPositive == bPositive
    rational = rationalReduce(exactMul(aNum, bDen), exactMul(aDen, bNum))
    imag = if aImag == bImag then '' else 'i'
    positive = not positive if !aImag and bImag
    sign = if positive then '' else '-'
    if rational
      return "#{sign}#{rational}#{imag}"
