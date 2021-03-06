

import Foundation

func curry<A, B, C>(f: (A, B) -> C) -> A -> B -> C {
    return { x in { y in f(x, y) } }
}

func flip<A, B, C>(f: (B, A) -> C) -> (A, B) -> C {
    return { (x, y) in f(y, x) }
}



func none<A>() -> SequenceOf<A> {
    return SequenceOf(GeneratorOf { nil } )
}
func one<A>(x: A) -> SequenceOf<A> {
    return SequenceOf(GeneratorOfOne(x))
}

struct JoinedGenerator<A>: GeneratorType {
    typealias Element = A
    
    var generator: GeneratorOf<GeneratorOf<A>>
    var current: GeneratorOf<A>?
    
    init(_ g: GeneratorOf<GeneratorOf<A>>) {
        generator = g
        current = generator.next()
    }
    
    mutating func next() -> A? {
        if var c = current {
            if let x = c.next() {
                return x
            } else {
                current = generator.next()
                return next()
            }
        }
        return nil
    }
}

func flatMap<A, B>(ls: SequenceOf<A>, 
                   f: A -> SequenceOf<B>) -> SequenceOf<B> {
                  
    return join(map(ls, f))
}

func map<A, B>(var g: GeneratorOf<A>, f: A -> B) -> GeneratorOf<B> {
    return GeneratorOf { map(g.next(), f) }
}

func map<A, B>(var s: SequenceOf<A>, f: A -> B) -> SequenceOf<B> {
    return SequenceOf {  map(s.generate(), f) }
}

func join<A>(s: SequenceOf<SequenceOf<A>>) -> SequenceOf<A> {
    return SequenceOf { 
        JoinedGenerator(map(s.generate()) { 
            $0.generate() 
        }) 
    }
}

func +<A>(l: SequenceOf<A>, r: SequenceOf<A>) -> SequenceOf<A> {
    return join(SequenceOf([l, r]))
}

func const<A, B>(x: A) -> B -> A {
    return { _ in x }
}

func prepend<A>(l: A) -> [A] -> [A] {
    return { (x: [A]) in [l] + x }
}

extension String {
    var characters: [Character] {
        var result: [Character] = []
        for c in self {
            result += [c]
        }
        return result
    }
    var slice: ArraySlice<Character> {
        let res = self.characters
        return res[0..<res.count]
    }
}

extension ArraySlice {
    var head: T? {
        return self.isEmpty ? nil : self[0]
    }
    
    var tail: ArraySlice<T> {
        if (self.isEmpty) {
            return self
        }
        return self[(self.startIndex+1)..<self.endIndex]
    }
    
    var decompose: (head: T, tail: ArraySlice<T>)? {
        return self.isEmpty ? nil 
                            : (self[self.startIndex], self.tail)
    }
}

extension Character: Printable {
    public var description: String {
       return "\"(self)\""
    }
}

func string(characters: [Character]) -> String {
    var s = ""
    s.extend(characters)
    return s
}

func member(set: NSCharacterSet, character: Character) -> Bool {
    let unichar = (String(character) as NSString).characterAtIndex(0)
    return set.characterIsMember(unichar)
}



struct Parser<Token, Result> {
    let p: ArraySlice<Token> -> SequenceOf<(Result, ArraySlice<Token>)>
}

infix operator <*> { associativity left precedence 150 }
func <*><Token, A, B>(l: Parser<Token, A -> B>,
                      r: Parser<Token, A>) -> Parser<Token, B> {
                      
    return Parser { input in                                          
        let leftResults = l.p(input)
        return flatMap(leftResults) { f, leftRemainder in
            let rightResults = r.p(leftRemainder)
            return map(rightResults) { x, y in (f(x), y) }
        }
    }
}

func pure<Token, A>(value: A) -> Parser<Token, A> {
    return Parser { one((value, $0)) }
}

infix operator </> { precedence 170 }
func </> <Token, A, B>(l: A -> B, 
                       r: Parser<Token, A>) -> Parser<Token, B> {
                       
    return pure(l) <*> r
}

infix operator <*  { associativity left precedence 150 }
func <* <Token, A, B>(p: Parser<Token, A>, 
                      q: Parser<Token, B>) -> Parser<Token, A> {
                      
    return {x in {_ in x} } </> p <*> q
}

infix operator  *> { associativity left precedence 150 }
func *> <Token, A, B>(p: Parser<Token, A>, 
                      q: Parser<Token, B>) -> Parser<Token, B> {
                      
    return {_ in {y in y} } </> p <*> q
}



func eof<A>() -> Parser<A, ()> {
    return Parser { stream in
        if (stream.isEmpty) {
            return one(((), stream))
        }
        return none()
    }
}

func testParser<A>(parser: Parser<Character, A>, 
                   input: String) -> String {
                   
    var result: [String] = []
    for (x, s) in parser.p(input.slice) {
        result += ["Success, found \(x), remainder: \(Array(s))"]
    }
    return result.isEmpty ? "Parsing failed." : join("\n", result)
}

//: 
//: Parser Combinators
//: ==================
//: 
//: Parsers are very useful tools: they take a list of tokens (usually, a
//: list of characters) and transform it into a structure. Often, parsers
//: are generated using an external tool, such as
//: [Bison](http://objc.io/fpinswift/20) or
//: [YACC](http://objc.io/fpinswift/21). Instead of using an external tool,
//: we'll build a parser library in this chapter, which we can use later for
//: building our own parser. Functional languages are very well suited for
//: this task.
//: 
//: There are several approaches to writing a parsing library. Here we'll
//: build a [parser combinator](http://objc.io/fpinswift/22) library. A
//: parser combinator is a [higher-order
//: function](http://objc.io/fpinswift/23) that takes several parsers as
//: input and returns a new parser as its output. The library we'll build is
//: an almost direct port of a Haskell library [-@swierstra:2009combinator],
//: with a few modifications.
//: 
//: We will start with defining a couple of core combinators. On top of
//: that, we will build some extra convenience functions, and finally, we
//: will show an example that parses arithmetic expressions, such as
//: `1+3*3`, and calculates the result.
//: 
//: The Core
//: --------
//: 
//: In this library, we'll make heavy use of
//: sequences and slices.
//: 
//: We define a parser as a function that takes a slice of tokens, processes
//: some of these tokens, and returns a tuple of the result and the
//: remainder of the tokens. To make our lives a bit easier, we wrap this
//: function in a struct (otherwise, we'd have to write out the entire type
//: every time). We make our parser generic over two types, `Token` and
//: `Result`:
//: 
//:
//:    struct Parser<Token, Result> {
//:        let p: ArraySlice<Token> -> SequenceOf<(Result, ArraySlice<Token>)>
//:    }
//:
//: 
//: We'd rather use a type alias to define our parser type, but type aliases
//: don't support generic types. Therefore, we have to live with the
//: indirection of using a struct in this case.
//: 
//: Let's start with a very simple parser that parses the single character
//: `"a"`. To do this, we write a function that returns the `"a"` character
//: parser:
//: 
//:
//:    func parseA() -> Parser<Character, Character>
//:
//: 
//: Note that it returns a parser with the token type `Character`, as well
//: as the result type `Character`. The results of this parser will be
//: tuples of an `"a"` character and the remainder of characters. It works
//: like this: it splits the input stream into head (the first character)
//: and tail (all remaining characters), and returns a single result if the
//: first character is an `"a"`. To return this single result, we use the
//: `one` function, defined analogously to the function `one` returning a
//: `Generator` in the previous chapter. If the first character isn't an
//: `"a"`, the parser fails by returning `none()`, which is simply an empty
//: sequence:
//: 

func parseA() -> Parser<Character, Character> {
    let a: Character = "a"
    return Parser { x in
        if let (head, tail) = x.decompose {
            if head == a { 
                return one((a, tail)) 
            }
        }
        return none()
    }
}

//: 
//: We can test it using the `testParser` function. This runs the parser
//: given by the first argument over the input string that is given by the
//: second argument. The parser will generate a sequence of possible
//: results, which get printed out by the `testParser` function. Usually, we
//: are only interested in the very first result:
//: 
testParser(parseA(), "abcd")
//: 
//: If we run the parser on a string that doesn't contain an `"a"` at the
//: start, we get a failure:
//: 
testParser(parseA(), "test")
//: 
//: We can easily abstract this function to work on any character. We pass
//: in the character as a parameter, and only return a result if the first
//: character in the stream is the same as the parameter:
//: 

func parseCharacter(character: Character) 
        -> Parser<Character, Character> {
        
    return Parser { x in
        if let (head, tail) = x.decompose {
            if head == character { 
                return one((character, tail)) 
            }
        }
        return none()
    }
}

//: 
//: Now we can test our new method:
//: 
testParser(parseCharacter("t"), "test")
//: 
//: We can abstract this method one final time, making it generic over any
//: kind of token. Instead of checking if the token is equal, we pass in a
//: function with type `Token -> Bool`, and if the function returns true for
//: the first character in the stream, we return it:
//: 

func satisfy<Token>(condition: Token -> Bool) 
        -> Parser<Token, Token> {
        
    return Parser { x in
        if let (head, tail) = x.decompose {
            if condition(head) { 
                return one((head, tail)) 
            }
        }
        return none()
    }
}

//: 
//: Now we can define a function `token` that works like `parseCharacter`,
//: the only difference being that it can be used with any type that
//: conforms to `Equatable`:
//: 

func token<Token: Equatable>(t: Token) -> Parser<Token, Token> {
    return satisfy { $0 == t }
}

//: 
//: Choice
//: ------
//: 
//: Parsing a single symbol isn't very useful, unless we add functions to
//: combine two parsers. The first function that we will introduce is the
//: choice operator, and it can parse using either the left operand or the
//: right operand. It is implemented in a simple way: given an input string,
//: it runs the left operand's parser, which yields a sequence of possible
//: results. Then it runs the right operand, which also yields a sequence of
//: possible results, and it concatenates the two sequences. Note that the
//: left and the right sequences might both be empty, or contain a lot of
//: elements. Because they are calculated lazily, it doesn't really matter:
//: 

infix operator <|> { associativity right precedence 130 }
func <|> <Token, A>(l: Parser<Token, A>, 
                    r: Parser<Token, A>) -> Parser<Token, A> {
                    
    return Parser { input in
        l.p(input) + r.p(input)
    }
}

//: 
//: To test our new operator, we build a parser that parses either an `"a"`
//: or a `"b"`:
//: 

let a: Character = "a"
let b: Character = "b"


testParser(token(a) <|> token(b), "bcd")
//: 
//: Sequence
//: --------
//: 
//: To combine two parsers that occur after each other, we'll start with a
//: more naive approach and expand that later to something more convenient
//: and powerful. First we write a `sequence` function:
//: 
//:
//:    func sequence<Token, A, B>(l: Parser<Token, A>, 
//:                               r: Parser<Token, B>) 
//:                               -> Parser<Token, (A, B)>
//:
//: 
//: The returned parser first uses the left parser to parse something of
//: type `A`. Let's say we wanted to parse the string `"xyz"` for an `"x"`
//: immediately followed by a `"y."` The left parser (the one looking for an
//: `"x"`) would then generate the following sequence containing a single
//: (result, remainder) tuple:
//: 
//:     [ ("x", "yz") ]
//: 
//: Applying the right parser to the remainder (`"yz"`) of the left parser's
//: tuple yields another sequence with one tuple:
//: 
//:     [ ("y", "z") ]
//: 
//: We then combine those tuples by grouping the `"x"` and `"y"` into a new
//: tuple ("x", "y"):
//: 
//:     [ (("x", "y"), "z") ]
//: 
//: Since we are doing these steps for each tuple in the returned sequence
//: of the left parser, we end up with a sequence of sequences:
//: 
//:     [ [ (("x", "y"), "z") ] ]
//: 
//: Finally, we flatten this structure to a simple sequence of
//: `((A, B), ArraySlice<Token>)` tuples. In code, the whole `sequence`
//: function looks like this:
//: 

func sequence<Token, A, B>(l: Parser<Token, A>, 
                           r: Parser<Token, B>) 
                           -> Parser<Token, (A, B)> {
                           
    return Parser { input in 
        let leftResults = l.p(input)
        return flatMap(leftResults) { a, leftRest in 
            let rightResults = r.p(leftRest)
            return map(rightResults, { b, rightRest in
                ((a, b), rightRest)
            })    
        }
    }
}

//: 
//: Note that the above parser only succeeds if both `l` and `r` succeed. If
//: they don't, no tokens are consumed.
//: 
//: We can test our parser by trying to parse a sequence of an `"x"`
//: followed by a `"y"`:
//: 

let x: Character = "x"
let y: Character = "y"


let p: Parser<Character, (Character, Character)> = 
        sequence(token(x), token(y))
testParser(p, "xyz")
//: 
//: ### Refining Sequences
//: 
//: The `sequence` function we wrote above is a first approach to combine
//: multiple parsers that are applied after each other. Imagine we wanted to
//: parse the same string `"xyz"` as above, but this time we want to parse
//: `"x"`, followed by `"y"`, followed by `"z"`. We could try to use the
//: `sequence` function in a nested way to combine three parsers:
//: 

let z: Character = "z"


let p2 = sequence(sequence(token(x), token(y)), token(z))
testParser(p2, "xyz")
//: 
//: The problem of this approach is that it yields a nested tuple
//: `(("x", "y"), "z")` instead of a flat one `("x", "y", "z")`. To rectify
//: this, we could write a `sequence3` function that combines three parsers
//: instead of just two:
//: 
func sequence3<Token, A, B, C>(p1: Parser<Token, A>, 
                               p2: Parser<Token, B>, 
                               p3: Parser<Token, C>) 
                               -> Parser<Token, (A, B, C)> {
                               
    return Parser { input in
        let p1Results = p1.p(input)
        return flatMap(p1Results) { a, p1Rest in
            let p2Results = p2.p(p1Rest)
            return flatMap(p2Results) {b, p2Rest in
                let p3Results = p3.p(p2Rest)
                return map(p3Results, { c, p3Rest in
                    ((a, b, c), p3Rest)
                })
            }
        }
    }
}

let p3 = sequence3(token(x), token(y), token(z))
testParser(p3, "xyz")
//: 
//: This returns the expected result, but the approach is way too inflexible
//: and doesn't scale. It turns out there is a much more convenient way to
//: combine multiple parsers in sequence.
//: 
//: As a first step, we create a parser that consumes no tokens at all, and
//: returns a function `A -> B`. This function takes on the job of
//: transforming the result of one or more other parsers in the way we want
//: it to. A very simple example of such a parser could be:
//: 

func integerParser<Token>() -> Parser<Token, Character -> Int> {
    return Parser { input in
        return one(({ x in String(x).toInt()! }, input))
    }
}

//: 
//: This parser doesn't consume any tokens and returns a function that takes
//: a character and turns it into an integer. Let's use the extremely simple
//: input stream `"3"` as example. Applying the `integerParser` to this
//: input yields the following sequence:
//: 
//:     [ (A -> B, "3") ]
//: 
//: Applying another parser to parse the symbol `"3"` in the remainder
//: (which is equal to the original input since the `integerParser` didn't
//: consume any tokens) yields:
//: 
//:     [ ("3", "") ]
//: 
//: Now we just have to create a function that combines these two parsers
//: and returns a new parser, so that the function yielded by
//: `integerParser` gets applied to the character `"3"` yielded by the
//: symbol parser. This function looks very similar to the `sequence`
//: function — it calls `flatMap` on the sequence returned by the first
//: parser, and then maps over the sequence returned by the second parser
//: applied to the remainder.
//: 
//: The key difference is that the inner closure does not return the results
//: of both parsers in a tuple as `sequence` did, but it applies the
//: function yielded by the first parser to the result of the second parser:
//: 

func combinator<Token, A, B>(l: Parser<Token, A -> B>,
                             r: Parser<Token, A>) 
                             -> Parser<Token, B> {
                                 
    return Parser { input in                                          
        let leftResults = l.p(input)
        return flatMap(leftResults) { f, leftRemainder in
            let rightResults = r.p(leftRemainder)
            return map(rightResults) { x, rightRemainder in 
                (f(x), rightRemainder) 
            }
        }
    }
}

//: 
//: Putting all of this together:
//: 

let three: Character = "3"


testParser(combinator(integerParser(), token(three)), "3")
//: 
//: Now we've laid the groundwork to build a really elegant parser
//: combination mechanism.
//: 
//: The first thing we'll do is refactor our `integerParser` function into a
//: generic function, with one parameter that returns a parser that always
//: succeeds, consumes no tokens, and returns the parameter we passed into
//: the function as result:
//: 
//:
//:    func pure<Token, A>(value: A) -> Parser<Token, A> {
//:        return Parser { one((value, $0)) }
//:    }
//:
//: 
//: With this in place, we can rewrite the previous example like this:
//: 
func toInteger(c: Character) -> Int {
    return String(c).toInt()!
}
testParser(combinator(pure(toInteger), token(three)), "3")
//: 
//: The whole trick to leverage this mechanism to combine multiple parsers
//: lies in the concept of currying.
//: Returning a curried function from the first parser enables us to go
//: through the combination process multiple times, depending on the number
//: of arguments of the curried function. For example:
//: 

func toInteger2(c1: Character)(c2: Character) -> Int {
    let combined = String(c1) + String(c2)
    return combined.toInt()!
}


testParser(combinator(combinator(pure(toInteger2), token(three)), 
                      token(three)), "33")
//: 
//: Since nesting a lot of `combinator` calls within each other is not very
//: readable, we define an operator for it:
//: 
//:
//:    infix operator <*> { associativity left precedence 150 }
//:    func <*><Token, A, B>(l: Parser<Token, A -> B>,
//:                          r: Parser<Token, A>) -> Parser<Token, B> {
//:                          
//:        return Parser { input in                                          
//:            let leftResults = l.p(input)
//:            return flatMap(leftResults) { f, leftRemainder in
//:                let rightResults = r.p(leftRemainder)
//:                return map(rightResults) { x, y in (f(x), y) }
//:            }
//:        }
//:    }
//:
//: 
//: Now we can express the previous example as:
//: 
testParser(pure(toInteger2) <*> token(three) <*> token(three), "33")
//: 
//: Notice that we have defined the `<*>` operator to have left precedence.
//: This means that the operator will first be applied to the left two
//: parsers, and then to the result of this operation and the right parser.
//: In other words, this behavior is exactly the same as our nested
//: `combinator` function calls above.
//: 
//: Another example of how we can now use this operator is to create a
//: parser that combines several characters into a string:
//: 

let aOrB = token(a) <|> token(b)


func combine(a: Character)(b: Character)(c: Character) -> String {
    return string([a, b, c])
}
let parser = pure(combine) <*> aOrB <*> aOrB <*> token(b)
testParser(parser, "abb")
//: 
//: In Chapter 3, we defined the `curry` function,
//: which curries a function with two parameters. We can define multiple
//: versions of the `curry` function, which work on functions with different
//: numbers of parameters. For example, we could define a variant that works
//: on a function with three arguments:
//: 

func curry<A, B, C, D>(f: (A, B, C) -> D) -> A -> B -> C -> D {
    return { a in { b in { c in f(a, b, c) } } }
}

//: 
//: Now, we can write the above parser in an even shorter way:
//: 
let parser2 = pure(curry { string([$0, $1, $2]) }) <*> aOrB 
              <*> aOrB <*> token(b)
testParser(parser2, "abb")
//: 
//: Convenience Combinators
//: -----------------------
//: 
//: Using the above combinators, we can already parse a lot of interesting
//: languages. However, they can be a bit tedious to express. Luckily, there
//: are some extra functions we can define to make life easier. First we
//: will define a function to parse a character from an `NSCharacterSet`.
//: This can be used, for example, to create a parser that parses decimal
//: digits:
//: 

func characterFromSet(set: NSCharacterSet) 
        -> Parser<Character, Character> {
        
    return satisfy { return member(set, $0) }
}

let decimals = NSCharacterSet.decimalDigitCharacterSet()
let decimalDigit = characterFromSet(decimals)

//: 
//: To verify that our `decimalDigit` parser works, we can run it on an
//: example input string:
//: 
testParser(decimalDigit, "012")
//: 
//: The next convenience combinator we want to write is a `zeroOrMore`
//: function, which executes a parser zero or more times:
//: 
//:
//:    func zeroOrMore<Token, A>(p: Parser<Token, A>) -> Parser<Token, [A]> {
//:        return (pure(prepend) <*> p <*> zeroOrMore(p)) <|> pure([])
//:    }
//:
//: 
//: The `prepend` function combines a value of type `A` and an array `[A]`
//: into a new array.
//: 
//: However, if we try to use this function, we will get stuck in an
//: infinite loop. That's because of the recursive call of `zeroOrMore` in
//: the return statement.
//: 
//: Luckily, we can use functions to defer the evaluation of the recursive
//: call to `zeroOrMore` until it is really needed, and with that, break the
//: infinite recursion. To do that, we will first define a helper function,
//: `lazy`. It returns a parser that will only be executed once it's
//: actually needed:
//: 

func lazy<Token, A>(f: () -> Parser<Token, A>)
        -> Parser<Token, A> {
        
    return Parser { x in f().p(x) }
}

//: 
//: Now we wrap the recursive call to `zeroOrMore` with this function:
//: 

func zeroOrMore<Token, A>(p: Parser<Token, A>) -> Parser<Token, [A]> {
    return (pure(prepend) <*> p <*> lazy { zeroOrMore(p) } ) <|> pure([])
}

//: 
//: Let's test the zeroOrMore combinator to see if it yields multiple
//: results. As we will see later on in this chapter, we usually only use
//: the first successful result of a parser, and the other ones will never
//: get computed, since they are lazily evaluated:
//: 
testParser(zeroOrMore(decimalDigit), "12345")
//: 
//: Another useful combinator is `oneOrMore`, which parses something one or
//: more times. It is defined using the `zeroOrMore` combinator:
//: 

func oneOrMore<Token, A>(p: Parser<Token, A>) -> Parser<Token, [A]> {
    return pure(prepend) <*> p <*> zeroOrMore(p)
}

//: 
//: If we parse one or more digits, we get back an array of digits in the
//: form of `Character`s. To convert this into an integer, we can first
//: convert the array of `Character`s into a string, and then just call the
//: built-in `toInt()` function on it. Even though `toInt` might return
//: `nil`, we know that it will succeed, so we can force it with the `!`
//: operator:
//: 

let number = pure { characters in string(characters).toInt()! }
             <*> oneOrMore(decimalDigit)


testParser(number, "205")
//: 
//: If we look at the code we've written so far, we see one recurring
//: pattern: `pure(x) <*> y`. In fact, it is so common that it's useful to
//: define an extra operator for it. If we look at the type, we can see that
//: it's very similar to a `map` function — it takes a function of type
//: `A -> B` and a parser of type `A`, and returns a parser of type `B`:
//: 
//:
//:    infix operator </> { precedence 170 }
//:    func </> <Token, A, B>(l: A -> B, 
//:                           r: Parser<Token, A>) -> Parser<Token, B> {
//:                           
//:        return pure(l) <*> r
//:    }
//:
//: 
//: Now we have defined a lot of useful functions, so it's time to start
//: combining some of them into real parsers. For example, if we want to
//: create a parser that can add two integers, we can now write it in the
//: following way:
//: 

let plus: Character = "+"
func add(x: Int)(_: Character)(y: Int) -> Int {
    return x + y
}
let parseAddition = add </> number <*> token(plus) <*> number

//: 
//: And we can again verify that it works:
//: 
testParser(parseAddition, "41+1")
//: 
//: It is often the case that we want to parse something but ignore the
//: result, for example, with the plus symbol in the parser above. We want
//: to know that it's there, but we do not care about the result of the
//: parser. We can define another operator, `<*`, which works exactly like
//: the `<*>` operator, except that it throws away the right-hand result
//: after parsing it (that's why the right angular bracket is missing in the
//: operator name). Similarly, we will also define a `*>` operator that
//: throws away the left-hand result:
//: 
//:
//:    infix operator <*  { associativity left precedence 150 }
//:    func <* <Token, A, B>(p: Parser<Token, A>, 
//:                          q: Parser<Token, B>) -> Parser<Token, A> {
//:                          
//:        return {x in {_ in x} } </> p <*> q
//:    }
//:    
//:    infix operator  *> { associativity left precedence 150 }
//:    func *> <Token, A, B>(p: Parser<Token, A>, 
//:                          q: Parser<Token, B>) -> Parser<Token, B> {
//:                          
//:        return {_ in {y in y} } </> p <*> q
//:    }
//:
//: 
//: Now we can write another parser for multiplication. It's very similar to
//: the `parseAddition` function, except that it uses our new `<*` operator
//: to throw away the `"*"` after parsing it:
//: 
let multiply: Character = "*"
let parseMultiplication = curry(*) </> number <* token(multiply) 
                          <*> number
testParser(parseMultiplication, "8*8")
//: 
//: A Simple Calculator
//: -------------------
//: 
//: We can extend our example to parse expressions like `10+4*3`. Here, it
//: is important to realize that when calculating the result, multiplication
//: takes precedence over addition. This is because of a rule in mathematics
//: (and programming) that's called *order of operations*. Expressing this
//: in our parser is quite natural. Let's start with the atoms, which take
//: the highest precedence:
//: 

typealias Calculator = Parser<Character, Int>


func operator0(character: Character, 
               evaluate: (Int, Int) -> Int, 
               operand: Calculator) -> Calculator {
               
   return curry { evaluate($0, $1) } </> operand 
          <* token(character) <*> operand
}

func pAtom0() -> Calculator { return number }
func pMultiply0() -> Calculator { return operator0("*", *, pAtom0()) }
func pAdd0() -> Calculator { return operator0("+", +, pMultiply0()) }
func pExpression0() -> Calculator { return pAdd0() }

testParser(pExpression0(), "1+3*3")
//: 
//: Why did the parsing fail?
//: 
//: First, an add expression is parsed. An add expression consists of a
//: multiplication expression, followed by a `"+"`, and then another
//: multiplication expression. `3*3` is a multiplication expression,
//: however, `1` is not. It's just a number. To fix this, we can change our
//: `operator` function to parse either an expression of the form
//: `operand operator operand`, or expressions consisting of a single
//: `operand`:
//: 

func operator1(character: Character, 
               evaluate: (Int, Int) -> Int, 
               operand: Calculator) -> Calculator {
               
   let withOperator = curry { evaluate($0, $1) } </> operand 
                      <* token(character) <*> operand
   return withOperator <|> operand
}

//: 
//: Now, we finally have a working variant:
//: 
func pAtom1() -> Calculator { return number }
func pMultiply1() -> Calculator { return operator1("*", *, pAtom1()) }
func pAdd1() -> Calculator { return operator1("+", +, pMultiply1()) }
func pExpression1() -> Calculator { return pAdd1() }

testParser(pExpression1(), "1+3*3")
//: 
//: If we want to add some more operators and abstract this a bit further,
//: we can create an array of operator characters and their interpretation
//: functions, and use the `reduce` function to combine them into one
//: parser:
//: 

typealias Op = (Character, (Int, Int) -> Int)
let operatorTable: [Op] = [("*", *), ("/", /), ("+", +), ("-", -)]


func pExpression2() -> Calculator {
    return operatorTable.reduce(number) { 
        (next: Calculator, op: Op) in
        operator1(op.0, op.1, next)
    }
}
testParser(pExpression2(), "1+3*3")
//: 
//: However, our parser becomes notably slow as we add more and more
//: operators. This is because the parser is constantly *backtracking*: it
//: tries to parse something, then fails, and tries another alternative. For
//: example, when trying to parse `"1+3*3"`, first, the `"-"` operator
//: (which consists of a `"+"` expression, followed by a `"-"` character,
//: and then another `"+"` expression) is tried. The first `"+"` expression
//: succeeds, but because no `"-"` character is found, it tries the
//: alternative: just a `"+"` expression. If we continue this, we can see
//: that a lot of unnecessary work is being done.
//: 
//: Writing a parser like the above is very simple. However, it is not very
//: efficient. If we take a step back and look at the grammar we've defined
//: using our parser combinators, we could write it down like this (in a
//: pseudo-grammar description language):
//: 
//:     expression = min
//:     min = add "-" add | add
//:     add = div "+" div | div
//:     div = mul "/" mul | mul
//:     mul = num "*" num | num
//: 
//: To remove a lot of the duplication, we can refactor the grammar like
//: this:
//: 
//:     expression = min
//:     min = add ("-" add)?
//:     add = div ("+" div)?
//:     div = mul ("/" mul)?
//:     mul = num ("*" num)?
//: 
//: Before we define the new operator function, we first define an
//: additional variant of the `</>` operator that consumes but doesn't use
//: its right operand:
//: 

infix operator </  { precedence 170 }
func </ <Token, A, B>(l: A, 
                      r: Parser<Token, B>) -> Parser<Token, A> {
                      
    return pure(l) <* r
}

//: 
//: Also, we will define a function, `optionallyFollowed`, which parses its
//: left operand, optionally followed by another part:
//: 

func optionallyFollowed<A>(l: Parser<Character, A>, 
                           r: Parser<Character, A -> A>) 
                           -> Parser<Character, A> {
                           
    let apply: A -> (A -> A) -> A = { x in { f in f(x) } }
    return apply </> l <*> (r <|> pure { $0 })
}

//: 
//: Finally, we can define our operator function. It works by parsing the
//: `operand` calculator, optionally followed by the operator and another
//: `operand` call. Note that instead of applying evaluate, we have to flip
//: it first (which swaps the order of the parameters). For some operators,
//: this isn't necessary (a + b is the same as b + a), but for others, it's
//: essential (a - b is not the same as b - a, unless b is zero):
//: 

func op(character: Character, 
        evaluate: (Int, Int) -> Int, 
        operand: Calculator) -> Calculator {
        
    let withOperator = curry(flip(evaluate)) </ token(character) 
                       <*> operand
    return optionallyFollowed(operand, withOperator)
}

//: 
//: We now finally have all the ingredients to once again define our
//: complete parser. Note that instead of giving just `pExpression()` to our
//: `testParser` function, we combine it with `eof()`. This makes sure that
//: the parser consumes all the input (an expression followed by the end of
//: the file):
//: 
func pExpression() -> Calculator {
    return operatorTable.reduce(number) { next, inOp in
        op(inOp.0, inOp.1, next)
    }
}
testParser(pExpression() <* eof(), "10-3*2")
//: 
//: This parser is much more efficient because it doesn't have to keep
//: parsing the same things over and over again. In the next chapter, we'll
//: use this parsing library to build a small spreadsheet application.
//: 
//: The calculator we built in this example still has significant
//: shortcomings, the most significant being the fact that you can only use
//: each operator once. In the spreadsheet example we're going to build in
//: the next chapter, we'll remedy this issue.
//: 
