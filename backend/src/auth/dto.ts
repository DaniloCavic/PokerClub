import { Transform } from 'class-transformer';
import { IsIn, IsInt, IsNumber, IsOptional, IsString, Matches, Max, MaxLength, Min, MinLength } from 'class-validator';

const trim = ({ value }: { value: unknown }) => (typeof value === 'string' ? value.trim() : value);

export class LoginDto {
  @Transform(trim)
  @IsString({ message: 'Unesite korisničko ime.' })
  @MinLength(1, { message: 'Unesite korisničko ime.' })
  username: string;

  @IsString({ message: 'Unesite lozinku.' })
  @MinLength(1, { message: 'Unesite lozinku.' })
  password: string;
}

export class ChangePasswordDto {
  @IsString()
  oldPassword: string;

  @IsString()
  @MinLength(6, { message: 'Nova lozinka mora imati bar 6 znakova.' })
  @MaxLength(100)
  newPassword: string;
}

export class CreateUserDto {
  @Transform(trim)
  @Matches(/^[A-Za-z0-9_.]{3,20}$/, {
    message: 'Korisničko ime: 3–20 znakova, samo slova bez kvačica, brojevi, tačka i donja crta.',
  })
  username: string;

  @Transform(trim)
  @IsString()
  @MinLength(2, { message: 'Ime za prikaz mora imati bar 2 znaka.' })
  @MaxLength(30, { message: 'Ime za prikaz može imati najviše 30 znakova.' })
  displayName: string;

  @IsString()
  @MinLength(6, { message: 'Lozinka mora imati bar 6 znakova.' })
  @MaxLength(100)
  password: string;

  /** Samo admin: kom agentu igrač pripada. */
  @IsOptional()
  @IsString()
  agentId?: string;

  @IsOptional()
  @IsString()
  @MaxLength(500)
  note?: string;
}

export class UpdateUserDto {
  @IsOptional()
  @Transform(trim)
  @IsString()
  @MinLength(2, { message: 'Ime za prikaz mora imati bar 2 znaka.' })
  @MaxLength(30)
  displayName?: string;

  @IsOptional()
  @IsString()
  @MinLength(6, { message: 'Lozinka mora imati bar 6 znakova.' })
  @MaxLength(100)
  password?: string;

  @IsOptional()
  @IsString()
  @MaxLength(500)
  note?: string;

  /** Samo admin: premeštanje igrača drugom agentu. */
  @IsOptional()
  @IsString()
  agentId?: string;
}

export class BlockDto {
  @IsOptional()
  @IsString()
  @MaxLength(200)
  reason?: string;
}

export class MoneyDto {
  @IsInt({ message: 'Iznos mora biti ceo broj.' })
  @Min(1, { message: 'Iznos mora biti veći od nule.' })
  @Max(1_000_000_000, { message: 'Iznos je prevelik.' })
  amount: number;

  @IsOptional()
  @IsString()
  @MaxLength(200)
  note?: string;
}

export class TableDto {
  @Transform(trim)
  @IsString()
  @MinLength(2, { message: 'Naziv stola mora imati bar 2 znaka.' })
  @MaxLength(40)
  name: string;

  @IsIn(['HOLDEM', 'OMAHA'], { message: "Igra mora biti Hold'em ili Omaha." })
  variant: 'HOLDEM' | 'OMAHA';

  @IsInt() @Min(1, { message: 'Mali blajnd mora biti bar 1.' }) @Max(1_000_000)
  smallBlind: number;

  @IsInt() @Min(2, { message: 'Veliki blajnd mora biti bar 2.' }) @Max(2_000_000)
  bigBlind: number;

  @IsInt() @Min(1) @Max(1_000_000_000)
  minBuyIn: number;

  @IsInt() @Min(1) @Max(1_000_000_000)
  maxBuyIn: number;

  @IsInt() @Min(2, { message: 'Sto mora imati 2–9 mesta.' }) @Max(9, { message: 'Sto mora imati 2–9 mesta.' })
  maxSeats: number;

  /** Rake u procentima, npr. 5 ili 2.5. */
  @IsNumber({}, { message: 'Rake mora biti broj.' })
  @Min(0, { message: 'Rake ne može biti negativan.' })
  @Max(10, { message: 'Rake može biti najviše 10 %.' })
  rakePercent: number;

  /** Najviše rake-a po ruci; 0 = bez ograničenja. */
  @IsInt() @Min(0) @Max(1_000_000_000)
  rakeCap: number;

  @IsInt() @Min(10, { message: 'Vreme za potez: 10–120 sekundi.' }) @Max(120, { message: 'Vreme za potez: 10–120 sekundi.' })
  actionSeconds: number;
}
