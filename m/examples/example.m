import { puts } from "externs.m"

type Color {
    r: UByte,
    g: UByte,
    b: UByte,
}

let colorAdd(self: Color, other: Color): Color {
	let result: Color = {
        .r = self.r + other.r,
        .g = self.g + other.g,
        .b = self.b + other.b,
    }
	return result
}

let colorGetRed(): Color {
	let result: Color = {
		.r = 0xFF,
		.g = 0x00,
		.b = 0x00,
	}
	return result
}

let colorGetGreen(): Color {
	let result: Color = {
		.r = 0x00,
		.g = 0xFF,
		.b = 0x00,
	}
	return result
}

let parseArgs(argc: UWord, argv: *UByte[]): Void {
	for i: UWord in 0..argc { // notice that 'i' here is a const 
		puts(argv[i])
		puts("\n")
	}

    for mut i: UWord in 0..argc { // notice that 'i' here is a mutable
		puts(argv[i])
		puts("\n")
	}

	// or through while
	let mut i: UWord = 0
	while i < argc {
		puts(argv[i])
		puts("\n")
		i++
	}
}

let main(argc: UWord, argv: *UByte[]): Word {
    puts("Hello, M!\n")

	let mut foo: Word = 42
	if foo == 42 {
		puts("42")
	} else if foo > 42 {
		puts("> 42")
	} else {
		puts("< 42")
	}
	puts("\n")
	
	parseArgs(argc, argv)

	let red: Color = colorGetRed()
	let green: Color = colorGetGreen()
	let add: Color = colorAdd(red, green)

    let mut flag: Bool = false
    if flag == false flag = true

	return 0
}

// Test directives (m/tests/run.py)
// @output "Hello, M!\n42\n"
// @exit 0
