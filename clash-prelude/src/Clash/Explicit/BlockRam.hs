{-|
Copyright  :  (C) 2013-2016, University of Twente,
                  2016-2017, Myrtle Software Ltd,
                  2017     , Google Inc.,
                  2021     , QBayLogic B.V.
License    :  BSD2 (see the file LICENSE)
Maintainer :  QBayLogic B.V. <devops@qbaylogic.com>

BlockRAM primitives

= Using RAMs #usingrams#

We will show a rather elaborate example on how you can, and why you might want
to use 'blockRam's. We will build a \"small\" CPU+Memory+Program ROM where we
will slowly evolve to using blockRams. Note that the code is /not/ meant as a
de-facto standard on how to do CPU design in Clash.

We start with the definition of the Instructions, Register names and machine
codes:

@
{\-\# LANGUAGE RecordWildCards, TupleSections, DeriveAnyClass \#-\}

module CPU where

import Clash.Explicit.Prelude

type InstrAddr = Unsigned 8
type MemAddr   = Unsigned 5
type Value     = Signed 8

data Instruction
  = Compute Operator Reg Reg Reg
  | Branch Reg Value
  | Jump Value
  | Load MemAddr Reg
  | Store Reg MemAddr
  | Nop
  deriving (Eq,Show)

data Reg
  = Zero
  | PC
  | RegA
  | RegB
  | RegC
  | RegD
  | RegE
  deriving (Eq,Show,Enum)

data Operator = Add | Sub | Incr | Imm | CmpGt
  deriving (Eq,Show)

data MachCode
  = MachCode
  { inputX  :: Reg
  , inputY  :: Reg
  , result  :: Reg
  , aluCode :: Operator
  , ldReg   :: Reg
  , rdAddr  :: MemAddr
  , wrAddrM :: Maybe MemAddr
  , jmpM    :: Maybe Value
  }

nullCode = MachCode { inputX = Zero, inputY = Zero, result = Zero, aluCode = Imm
                    , ldReg = Zero, rdAddr = 0, wrAddrM = Nothing
                    , jmpM = Nothing
                    }
@

Next we define the CPU and its ALU:

@
cpu
  :: Vec 7 Value
  -- ^ Register bank
  -> (Value,Instruction)
  -- ^ (Memory output, Current instruction)
  -> ( Vec 7 Value
     , (MemAddr, Maybe (MemAddr,Value), InstrAddr)
     )
cpu regbank (memOut,instr) = (regbank',(rdAddr,(,aluOut) '<$>' wrAddrM,fromIntegral ipntr))
  where
    -- Current instruction pointer
    ipntr = regbank 'Clash.Sized.Vector.!!' PC

    -- Decoder
    (MachCode {..}) = case instr of
      Compute op rx ry res -> nullCode {inputX=rx,inputY=ry,result=res,aluCode=op}
      Branch cr a          -> nullCode {inputX=cr,jmpM=Just a}
      Jump a               -> nullCode {aluCode=Incr,jmpM=Just a}
      Load a r             -> nullCode {ldReg=r,rdAddr=a}
      Store r a            -> nullCode {inputX=r,wrAddrM=Just a}
      Nop                  -> nullCode

    -- ALU
    regX   = regbank 'Clash.Sized.Vector.!!' inputX
    regY   = regbank 'Clash.Sized.Vector.!!' inputY
    aluOut = alu aluCode regX regY

    -- next instruction
    nextPC = case jmpM of
               Just a | aluOut /= 0 -> ipntr + a
               _                    -> ipntr + 1

    -- update registers
    regbank' = 'Clash.Sized.Vector.replace' Zero   0
             $ 'Clash.Sized.Vector.replace' PC     nextPC
             $ 'Clash.Sized.Vector.replace' result aluOut
             $ 'Clash.Sized.Vector.replace' ldReg  memOut
             $ regbank

alu Add   x y = x + y
alu Sub   x y = x - y
alu Incr  x _ = x + 1
alu Imm   x _ = x
alu CmpGt x y = if x > y then 1 else 0
@

We initially create a memory out of simple registers:

@
dataMem
  :: KnownDomain dom
  => Clock dom
  -> Reset dom
  -> Enable dom
  -> Signal dom MemAddr
  -- ^ Read address
  -> Signal dom (Maybe (MemAddr,Value))
  -- ^ (write address, data in)
  -> Signal dom Value
  -- ^ data out
dataMem clk rst en rd wrM = 'Clash.Explicit.Mealy.mealy' clk rst en dataMemT ('Clash.Sized.Vector.replicate' d32 0) (bundle (rd,wrM))
  where
    dataMemT mem (rd,wrM) = (mem',dout)
      where
        dout = mem 'Clash.Sized.Vector.!!' rd
        mem' = case wrM of
                 Just (wr,din) -> 'Clash.Sized.Vector.replace' wr din mem
                 _ -> mem
@

And then connect everything:

@
system
  :: ( KnownDomain dom
     , KnownNat n )
  => Vec n Instruction
  -> Clock dom
  -> Reset dom
  -> Enable dom
  -> Signal dom Value
system instrs clk rst en = memOut
  where
    memOut = dataMem clk rst en rdAddr dout
    (rdAddr,dout,ipntr) = 'Clash.Explicit.Mealy.mealyB' clk rst en cpu ('Clash.Sized.Vector.replicate' d7 0) (memOut,instr)
    instr  = 'Clash.Explicit.Prelude.asyncRom' instrs '<$>' ipntr
@

Create a simple program that calculates the GCD of 4 and 6:

@
-- Compute GCD of 4 and 6
prog = -- 0 := 4
       Compute Incr Zero RegA RegA :>
       replicate d3 (Compute Incr RegA Zero RegA) ++
       Store RegA 0 :>
       -- 1 := 6
       Compute Incr Zero RegA RegA :>
       replicate d5 (Compute Incr RegA Zero RegA) ++
       Store RegA 1 :>
       -- A := 4
       Load 0 RegA :>
       -- B := 6
       Load 1 RegB :>
       -- start
       Compute CmpGt RegA RegB RegC :>
       Branch RegC 4 :>
       Compute CmpGt RegB RegA RegC :>
       Branch RegC 4 :>
       Jump 5 :>
       -- (a > b)
       Compute Sub RegA RegB RegA :>
       Jump (-6) :>
       -- (b > a)
       Compute Sub RegB RegA RegB :>
       Jump (-8) :>
       -- end
       Store RegA 2 :>
       Load 2 RegC :>
       Nil
@

And test our system:

@
>>> sampleN 32 $ system prog systemClockGen resetGen enableGen
[0,0,0,0,0,0,4,4,4,4,4,4,4,4,6,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,2]

@

to see that our system indeed calculates that the GCD of 6 and 4 is 2.

=== Improvement 1: using @asyncRam@

As you can see, it's fairly straightforward to build a memory using registers
and read ('Clash.Sized.Vector.!!') and write ('Clash.Sized.Vector.replace')
logic. This might however not result in the most efficient hardware structure,
especially when building an ASIC.

Instead it is preferable to use the 'Clash.Prelude.RAM.asyncRam' function which
has the potential to be translated to a more efficient structure:

@
system2
  :: ( KnownDomain dom
     , KnownNat n )
  => Vec n Instruction
  -> Clock dom
  -> Reset dom
  -> Enable dom
  -> Signal dom Value
system2 instrs clk rst en = memOut
  where
    memOut = 'Clash.Explicit.RAM.asyncRam' clk clk en d32 rdAddr dout
    (rdAddr,dout,ipntr) = 'Clash.Explicit.Prelude.mealyB' clk rst en cpu ('Clash.Sized.Vector.replicate' d7 0) (memOut,instr)
    instr  = 'Clash.Prelude.ROM.asyncRom' instrs '<$>' ipntr
@

Again, we can simulate our system and see that it works. This time however,
we need to disregard the first few output samples, because the initial content of an
'Clash.Prelude.RAM.asyncRam' is /undefined/, and consequently, the first few
output samples are also /undefined/. We use the utility function
'Clash.XException.printX' to conveniently filter out the undefinedness and
replace it with the string "X" in the few leading outputs.

@
>>> printX $ sampleN 32 $ system2 prog systemClockGen resetGen enableGen
[undefined,undefined,undefined,undefined,undefined,undefined,4,4,4,4,4,4,4,4,6,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,2]

@

=== Improvement 2: using @blockRam@

Finally we get to using 'blockRam'. On FPGAs, 'Clash.Prelude.RAM.asyncRam' will
be implemented in terms of LUTs, and therefore take up logic resources. FPGAs
also have large(r) memory structures called /Block RAMs/, which are preferred,
especially as the memories we need for our application get bigger. The
'blockRam' function will be translated to such a /Block RAM/.

One important aspect of Block RAMs have a /synchronous/ read port, meaning that,
unlike the behavior of 'Clash.Prelude.RAM.asyncRam', given a read address @r@
at time @t@, the value @v@ in the RAM at address @r@ is only available at time
@t+1@.

For us that means we need to change the design of our CPU. Right now, upon a
load instruction we generate a read address for the memory, and the value at
that read address is immediately available to be put in the register bank.
Because we will be using a BlockRAM, the value is delayed until the next cycle.
We hence need to also delay the register address to which the memory address
is loaded:

@
cpu2
  :: (Vec 7 Value,Reg)
  -- ^ (Register bank, Load reg addr)
  -> (Value,Instruction)
  -- ^ (Memory output, Current instruction)
  -> ( (Vec 7 Value,Reg)
     , (MemAddr, Maybe (MemAddr,Value), InstrAddr)
     )
cpu2 (regbank,ldRegD) (memOut,instr) = ((regbank',ldRegD'),(rdAddr,(,aluOut) '<$>' wrAddrM,fromIntegral ipntr))
  where
    -- Current instruction pointer
    ipntr = regbank 'Clash.Sized.Vector.!!' PC

    -- Decoder
    (MachCode {..}) = case instr of
      Compute op rx ry res -> nullCode {inputX=rx,inputY=ry,result=res,aluCode=op}
      Branch cr a          -> nullCode {inputX=cr,jmpM=Just a}
      Jump a               -> nullCode {aluCode=Incr,jmpM=Just a}
      Load a r             -> nullCode {ldReg=r,rdAddr=a}
      Store r a            -> nullCode {inputX=r,wrAddrM=Just a}
      Nop                  -> nullCode

    -- ALU
    regX   = regbank 'Clash.Sized.Vector.!!' inputX
    regY   = regbank 'Clash.Sized.Vector.!!' inputY
    aluOut = alu aluCode regX regY

    -- next instruction
    nextPC = case jmpM of
               Just a | aluOut /= 0 -> ipntr + a
               _                    -> ipntr + 1

    -- update registers
    ldRegD'  = ldReg -- Delay the ldReg by 1 cycle
    regbank' = 'Clash.Sized.Vector.replace' Zero   0
             $ 'Clash.Sized.Vector.replace' PC     nextPC
             $ 'Clash.Sized.Vector.replace' result aluOut
             $ 'Clash.Sized.Vector.replace' ldRegD memOut
             $ regbank
@

We can now finally instantiate our system with a 'blockRam':

@
system3
  :: ( KnownDomain dom
     , KnownNat n )
  => Vec n Instruction
  -> Clock dom
  -> Reset dom
  -> Enable dom
  -> Signal dom Value
system3 instrs clk rst en = memOut
  where
    memOut = 'blockRam' clk en (replicate d32 0) rdAddr dout
    (rdAddr,dout,ipntr) = 'Clash.Explicit.Prelude.mealyB' clk rst en cpu2 (('Clash.Sized.Vector.replicate' d7 0),Zero) (memOut,instr)
    instr  = 'Clash.Explicit.Prelude.asyncRom' instrs '<$>' ipntr
@

We are, however, not done. We will also need to update our program. The reason
being that values that we try to load in our registers won't be loaded into the
register until the next cycle. This is a problem when the next instruction
immediately depended on this memory value. In our case, this was only the case
when the loaded the value @6@, which was stored at address @1@, into @RegB@.
Our updated program is thus:

@
prog2 = -- 0 := 4
       Compute Incr Zero RegA RegA :>
       replicate d3 (Compute Incr RegA Zero RegA) ++
       Store RegA 0 :>
       -- 1 := 6
       Compute Incr Zero RegA RegA :>
       replicate d5 (Compute Incr RegA Zero RegA) ++
       Store RegA 1 :>
       -- A := 4
       Load 0 RegA :>
       -- B := 6
       Load 1 RegB :>
       Nop :> -- Extra NOP
       -- start
       Compute CmpGt RegA RegB RegC :>
       Branch RegC 4 :>
       Compute CmpGt RegB RegA RegC :>
       Branch RegC 4 :>
       Jump 5 :>
       -- (a > b)
       Compute Sub RegA RegB RegA :>
       Jump (-6) :>
       -- (b > a)
       Compute Sub RegB RegA RegB :>
       Jump (-8) :>
       -- end
       Store RegA 2 :>
       Load 2 RegC :>
       Nil
@

When we simulate our system we see that it works. This time again,
we need to disregard the first sample, because the initial output of a
'blockRam' is /undefined/. We use the utility function 'Clash.XException.printX'
to conveniently filter out the undefinedness and replace it with the string "X".

@
>>> printX $ sampleN 34 $ system3 prog2 systemClockGen resetGen enableGen
[undefined,0,0,0,0,0,0,4,4,4,4,4,4,4,4,6,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,2]

@

This concludes the short introduction to using 'blockRam'.

-}

-- Necessary to derive NFDataX for RamOp
{-# LANGUAGE DeriveAnyClass#-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NoImplicitPrelude #-}

{-# LANGUAGE Trustworthy #-}

{-# OPTIONS_GHC -fplugin GHC.TypeLits.KnownNat.Solver #-}
{-# OPTIONS_HADDOCK show-extensions #-}

-- Prevent generation of eta port names for trueDualPortBlockRam
{-# OPTIONS_GHC -fno-do-lambda-eta-expansion #-}

-- See: https://github.com/clash-lang/clash-compiler/commit/721fcfa9198925661cd836668705f817bddaae3c
-- as to why we need this.
{-# OPTIONS_GHC -fno-cpr-anal #-}

module Clash.Explicit.BlockRam
  ( -- * BlockRAM synchronized to the system clock
    blockRam
  , blockRamPow2
  , blockRamU
  , blockRam1
  , trueDualPortBlockRam
  , RamOp(..)
  , WriteMode(..)
  , TDPConfig(..)
  , ResetStrategy(..)
    -- * Read/Write conflict resolution
  , readNew
    -- * Internal
  , blockRam#
  , trueDualPortBlockRam#
  , tdpDefault
  )
where

import           Clash.HaskellPrelude

import           Control.Exception      (catch, throw)
import           Control.Monad          (forM_)
import           Control.Monad.ST       (ST, runST)
import           Control.Monad.ST.Unsafe (unsafeInterleaveST, unsafeIOToST, unsafeSTToIO)
import           Data.Array.MArray      (newListArray)
import qualified Data.List              as L
import           Data.Either            (isLeft)
import           Data.Maybe             (isJust, fromMaybe)
import           GHC.Arr
  (STArray, unsafeReadSTArray, unsafeWriteSTArray)
import qualified Data.Sequence          as Seq
import           Data.Sequence          (Seq)
import           Data.Tuple             (swap)
import           GHC.Generics           (Generic) -- derived by RamOp
import           GHC.Stack              (HasCallStack, withFrozenCallStack)
import           GHC.TypeLits           (KnownNat, type (^), type (<=))
import           Unsafe.Coerce          (unsafeCoerce)

import           Clash.Annotations.Primitive
  (hasBlackBox)
import           Clash.Class.Num        (SaturationMode(SatBound), satSucc)
import           Clash.Explicit.Signal  (KnownDomain, Enable, register, fromEnable)
import           Clash.Signal.Internal
  (Clock(..), Reset, Signal (..), invertReset, (.&&.), mux)
import           Clash.Promoted.Nat     (SNat(..), snatToNum, natToNum)
import           Clash.Signal.Bundle    (unbundle, bundle)
import           Clash.Signal.Internal.Ambiguous (clockPeriod)
import           Clash.Sized.Unsigned   (Unsigned)
import           Clash.Sized.Index      (Index)
import           Clash.Sized.Vector     (Vec, replicate, iterateI)
import qualified Clash.Sized.Vector     as CV
import           Clash.XException
  (maybeIsX, NFDataX, deepErrorX, defaultSeqX, fromJustX, undefined,
   XException (..), seqX, isX)

-- start benchmark only
-- import GHC.Arr (listArray, unsafeThawSTArray)
-- end benchmark only

{- $setup
>>> :m -Clash.Prelude
>>> :m -Clash.Prelude.Safe
>>> import Clash.Explicit.Prelude as C
>>> import qualified Data.List as L
>>> :set -XDataKinds -XRecordWildCards -XTupleSections -XDeriveAnyClass -XDeriveGeneric
>>> type InstrAddr = Unsigned 8
>>> type MemAddr = Unsigned 5
>>> type Value = Signed 8
>>> :{
data Reg
  = Zero
  | PC
  | RegA
  | RegB
  | RegC
  | RegD
  | RegE
  deriving (Eq,Show,Enum,C.Generic,NFDataX)
:}

>>> :{
data Operator = Add | Sub | Incr | Imm | CmpGt
  deriving (Eq,Show)
:}

>>> :{
data Instruction
  = Compute Operator Reg Reg Reg
  | Branch Reg Value
  | Jump Value
  | Load MemAddr Reg
  | Store Reg MemAddr
  | Nop
  deriving (Eq,Show)
:}

>>> :{
data MachCode
  = MachCode
  { inputX  :: Reg
  , inputY  :: Reg
  , result  :: Reg
  , aluCode :: Operator
  , ldReg   :: Reg
  , rdAddr  :: MemAddr
  , wrAddrM :: Maybe MemAddr
  , jmpM    :: Maybe Value
  }
:}

>>> :{
nullCode = MachCode { inputX = Zero, inputY = Zero, result = Zero, aluCode = Imm
                    , ldReg = Zero, rdAddr = 0, wrAddrM = Nothing
                    , jmpM = Nothing
                    }
:}

>>> :{
alu Add   x y = x + y
alu Sub   x y = x - y
alu Incr  x _ = x + 1
alu Imm   x _ = x
alu CmpGt x y = if x > y then 1 else 0
:}

>>> :{
let cpu :: Vec 7 Value          -- ^ Register bank
        -> (Value,Instruction)  -- ^ (Memory output, Current instruction)
        -> ( Vec 7 Value
           , (MemAddr,Maybe (MemAddr,Value),InstrAddr)
           )
    cpu regbank (memOut,instr) = (regbank',(rdAddr,(,aluOut) <$> wrAddrM,fromIntegral ipntr))
      where
        -- Current instruction pointer
        ipntr = regbank C.!! PC
        -- Decoder
        (MachCode {..}) = case instr of
          Compute op rx ry res -> nullCode {inputX=rx,inputY=ry,result=res,aluCode=op}
          Branch cr a          -> nullCode {inputX=cr,jmpM=Just a}
          Jump a               -> nullCode {aluCode=Incr,jmpM=Just a}
          Load a r             -> nullCode {ldReg=r,rdAddr=a}
          Store r a            -> nullCode {inputX=r,wrAddrM=Just a}
          Nop                  -> nullCode
        -- ALU
        regX   = regbank C.!! inputX
        regY   = regbank C.!! inputY
        aluOut = alu aluCode regX regY
        -- next instruction
        nextPC = case jmpM of
                   Just a | aluOut /= 0 -> ipntr + a
                   _                    -> ipntr + 1
        -- update registers
        regbank' = replace Zero   0
                 $ replace PC     nextPC
                 $ replace result aluOut
                 $ replace ldReg  memOut
                 $ regbank
:}

>>> :{
let dataMem
      :: KnownDomain dom
      => Clock  dom
      -> Reset  dom
      -> Enable dom
      -> Signal dom MemAddr
      -> Signal dom (Maybe (MemAddr,Value))
      -> Signal dom Value
    dataMem clk rst en rd wrM = mealy clk rst en dataMemT (C.replicate d32 0) (bundle (rd,wrM))
      where
        dataMemT mem (rd,wrM) = (mem',dout)
          where
            dout = mem C.!! rd
            mem' = case wrM of
                     Just (wr,din) -> replace wr din mem
                     Nothing       -> mem
:}

>>> :{
let system
      :: ( KnownDomain dom
         , KnownNat n )
      => Vec n Instruction
      -> Clock dom
      -> Reset dom
      -> Enable dom
      -> Signal dom Value
    system instrs clk rst en = memOut
      where
        memOut = dataMem clk rst en rdAddr dout
        (rdAddr,dout,ipntr) = mealyB clk rst en cpu (C.replicate d7 0) (memOut,instr)
        instr  = asyncRom instrs <$> ipntr
:}

>>> :{
-- Compute GCD of 4 and 6
prog = -- 0 := 4
       Compute Incr Zero RegA RegA :>
       C.replicate d3 (Compute Incr RegA Zero RegA) C.++
       Store RegA 0 :>
       -- 1 := 6
       Compute Incr Zero RegA RegA :>
       C.replicate d5 (Compute Incr RegA Zero RegA) C.++
       Store RegA 1 :>
       -- A := 4
       Load 0 RegA :>
       -- B := 6
       Load 1 RegB :>
       -- start
       Compute CmpGt RegA RegB RegC :>
       Branch RegC 4 :>
       Compute CmpGt RegB RegA RegC :>
       Branch RegC 4 :>
       Jump 5 :>
       -- (a > b)
       Compute Sub RegA RegB RegA :>
       Jump (-6) :>
       -- (b > a)
       Compute Sub RegB RegA RegB :>
       Jump (-8) :>
       -- end
       Store RegA 2 :>
       Load 2 RegC :>
       Nil
:}

>>> :{
let system2
      :: ( KnownDomain dom
         , KnownNat n )
      => Vec n Instruction
      -> Clock dom
      -> Reset dom
      -> Enable dom
      -> Signal dom Value
    system2 instrs clk rst en = memOut
      where
        memOut = asyncRam clk clk en d32 rdAddr dout
        (rdAddr,dout,ipntr) = mealyB clk rst en cpu (C.replicate d7 0) (memOut,instr)
        instr  = asyncRom instrs <$> ipntr
:}

>>> :{
let cpu2 :: (Vec 7 Value,Reg)    -- ^ (Register bank, Load reg addr)
         -> (Value,Instruction)  -- ^ (Memory output, Current instruction)
         -> ( (Vec 7 Value,Reg)
            , (MemAddr,Maybe (MemAddr,Value),InstrAddr)
            )
    cpu2 (regbank,ldRegD) (memOut,instr) = ((regbank',ldRegD'),(rdAddr,(,aluOut) <$> wrAddrM,fromIntegral ipntr))
      where
        -- Current instruction pointer
        ipntr = regbank C.!! PC
        -- Decoder
        (MachCode {..}) = case instr of
          Compute op rx ry res -> nullCode {inputX=rx,inputY=ry,result=res,aluCode=op}
          Branch cr a          -> nullCode {inputX=cr,jmpM=Just a}
          Jump a               -> nullCode {aluCode=Incr,jmpM=Just a}
          Load a r             -> nullCode {ldReg=r,rdAddr=a}
          Store r a            -> nullCode {inputX=r,wrAddrM=Just a}
          Nop                  -> nullCode
        -- ALU
        regX   = regbank C.!! inputX
        regY   = regbank C.!! inputY
        aluOut = alu aluCode regX regY
        -- next instruction
        nextPC = case jmpM of
                   Just a | aluOut /= 0 -> ipntr + a
                   _                    -> ipntr + 1
        -- update registers
        ldRegD'  = ldReg -- Delay the ldReg by 1 cycle
        regbank' = replace Zero   0
                 $ replace PC     nextPC
                 $ replace result aluOut
                 $ replace ldRegD memOut
                 $ regbank
:}

>>> :{
let system3
      :: ( KnownDomain dom
         , KnownNat n )
      => Vec n Instruction
      -> Clock dom
      -> Reset dom
      -> Enable dom
      -> Signal dom Value
    system3 instrs clk rst en = memOut
      where
        memOut = blockRam clk en (C.replicate d32 0) rdAddr dout
        (rdAddr,dout,ipntr) = mealyB clk rst en cpu2 ((C.replicate d7 0),Zero) (memOut,instr)
        instr  = asyncRom instrs <$> ipntr
:}

>>> :{
prog2 = -- 0 := 4
       Compute Incr Zero RegA RegA :>
       C.replicate d3 (Compute Incr RegA Zero RegA) C.++
       Store RegA 0 :>
       -- 1 := 6
       Compute Incr Zero RegA RegA :>
       C.replicate d5 (Compute Incr RegA Zero RegA) C.++
       Store RegA 1 :>
       -- A := 4
       Load 0 RegA :>
       -- B := 6
       Load 1 RegB :>
       Nop :> -- Extra NOP
       -- start
       Compute CmpGt RegA RegB RegC :>
       Branch RegC 4 :>
       Compute CmpGt RegB RegA RegC :>
       Branch RegC 4 :>
       Jump 5 :>
       -- (a > b)
       Compute Sub RegA RegB RegA :>
       Jump (-6) :>
       -- (b > a)
       Compute Sub RegB RegA RegB :>
       Jump (-8) :>
       -- end
       Store RegA 2 :>
       Load 2 RegC :>
       Nil
:}

-}

-- | Create a blockRAM with space for @n@ elements
--
-- * __NB__: Read value is delayed by 1 cycle
-- * __NB__: Initial output value is /undefined/
--
-- @
-- bram40
--   :: 'Clock'  dom
--   -> 'Enable'  dom
--   -> 'Signal' dom ('Unsigned' 6)
--   -> 'Signal' dom (Maybe ('Unsigned' 6, 'Clash.Sized.BitVector.Bit'))
--   -> 'Signal' dom 'Clash.Sized.BitVector.Bit'
-- bram40 clk en = 'blockRam' clk en ('Clash.Sized.Vector.replicate' d40 1)
-- @
--
-- Additional helpful information:
--
-- * See "Clash.Explicit.BlockRam#usingrams" for more information on how to use a
-- Block RAM.
-- * Use the adapter 'readNew' for obtaining write-before-read semantics like this: @'readNew' clk rst ('blockRam' clk inits) rd wrM@.
blockRam
  :: ( KnownDomain dom
     , HasCallStack
     , NFDataX a
     , Enum addr )
  => Clock dom
  -- ^ 'Clock' to synchronize to
  -> Enable dom
  -- ^ Global enable
  -> Vec n a
  -- ^ Initial content of the BRAM, also determines the size, @n@, of the BRAM.
   --
   -- __NB__: __MUST__ be a constant.
  -> Signal dom addr
  -- ^ Read address @r@
  -> Signal dom (Maybe (addr, a))
  -- ^ (write address @w@, value to write)
  -> Signal dom a
  -- ^ Value of the @blockRAM@ at address @r@ from the previous clock cycle
blockRam = \clk gen content rd wrM ->
  let en       = isJust <$> wrM
      (wr,din) = unbundle (fromJustX <$> wrM)
  in  withFrozenCallStack
      (blockRam# clk gen content (fromEnum <$> rd) en (fromEnum <$> wr) din)
{-# INLINE blockRam #-}

-- | Create a blockRAM with space for 2^@n@ elements
--
-- * __NB__: Read value is delayed by 1 cycle
-- * __NB__: Initial output value is /undefined/
--
-- @
-- bram32
--   :: 'Clock' dom
--   -> 'Enable' dom
--   -> 'Signal' dom ('Unsigned' 5)
--   -> 'Signal' dom (Maybe ('Unsigned' 5, 'Clash.Sized.BitVector.Bit'))
--   -> 'Signal' dom 'Clash.Sized.BitVector.Bit'
-- bram32 clk en = 'blockRamPow2' clk en ('Clash.Sized.Vector.replicate' d32 1)
-- @
--
-- Additional helpful information:
--
-- * See "Clash.Prelude.BlockRam#usingrams" for more information on how to use a
-- Block RAM.
-- * Use the adapter 'readNew' for obtaining write-before-read semantics like this: @'readNew' clk rst ('blockRamPow2' clk inits) rd wrM@.
blockRamPow2
  :: ( KnownDomain dom
     , HasCallStack
     , NFDataX a
     , KnownNat n )
  => Clock dom
  -- ^ 'Clock' to synchronize to
  -> Enable dom
  -- ^ Global enable
  -> Vec (2^n) a
  -- ^ Initial content of the BRAM, also
  -- determines the size, @2^n@, of
  -- the BRAM.
  --
  -- __NB__: __MUST__ be a constant.
  -> Signal dom (Unsigned n)
  -- ^ Read address @r@
  -> Signal dom (Maybe (Unsigned n, a))
  -- ^ (Write address @w@, value to write)
  -> Signal dom a
  -- ^ Value of the @blockRAM@ at address @r@ from the previous
  -- clock cycle
blockRamPow2 = \clk en cnt rd wrM -> withFrozenCallStack
  (blockRam clk en cnt rd wrM)
{-# INLINE blockRamPow2 #-}

data ResetStrategy (r :: Bool) where
  ClearOnReset :: ResetStrategy 'True
  NoClearOnReset :: ResetStrategy 'False

-- | Version of blockram that has no default values set. May be cleared to a
-- arbitrary state using a reset function.
blockRamU
   :: forall n dom a r addr
   . ( KnownDomain dom
     , HasCallStack
     , NFDataX a
     , Enum addr
     , 1 <= n )
  => Clock dom
  -- ^ 'Clock' to synchronize to
  -> Reset dom
  -- ^ 'Reset' line to listen to. Needs to be held at least /n/ cycles in order
  -- for the BRAM to be reset to its initial state.
  -> Enable dom
  -- ^ Global enable
  -> ResetStrategy r
  -- ^ Whether to clear BRAM on asserted reset ('ClearOnReset') or
  -- not ('NoClearOnReset'). Reset needs to be asserted at least /n/ cycles to
  -- clear the BRAM.
  -> SNat n
  -- ^ Number of elements in BRAM
  -> (Index n -> a)
  -- ^ If applicable (see first argument), reset BRAM using this function.
  -> Signal dom addr
  -- ^ Read address @r@
  -> Signal dom (Maybe (addr, a))
  -- ^ (write address @w@, value to write)
  -> Signal dom a
  -- ^ Value of the @blockRAM@ at address @r@ from the previous clock cycle
blockRamU clk rst0 en rstStrategy n@SNat initF rd0 mw0 =
  case rstStrategy of
    ClearOnReset ->
      -- Use reset infrastructure
      blockRamU# clk en n rd1 we1 wa1 w1
    NoClearOnReset ->
      -- Ignore reset infrastructure, pass values unchanged
      blockRamU# clk en n
        (fromEnum <$> rd0)
        we0
        (fromEnum <$> wa0)
        w0
 where
  rstBool = register clk rst0 en True (pure False)
  rstInv = invertReset rst0

  waCounter :: Signal dom (Index n)
  waCounter = register clk rstInv en 0 (satSucc SatBound <$> waCounter)

  wa0 = fst . fromJustX <$> mw0
  w0  = snd . fromJustX <$> mw0
  we0 = isJust <$> mw0

  rd1 = mux rstBool 0 (fromEnum <$> rd0)
  we1 = mux rstBool (pure True) we0
  wa1 = mux rstBool (fromInteger . toInteger <$> waCounter) (fromEnum <$> wa0)
  w1  = mux rstBool (initF <$> waCounter) w0

-- | blockRAMU primitive
blockRamU#
  :: forall n dom a
   . ( KnownDomain dom
     , HasCallStack
     , NFDataX a )
  => Clock dom
  -- ^ 'Clock' to synchronize to
  -> Enable dom
  -- ^ Global Enable
  -> SNat n
  -- ^ Number of elements in BRAM
  -> Signal dom Int
  -- ^ Read address @r@
  -> Signal dom Bool
  -- ^ Write enable
  -> Signal dom Int
  -- ^ Write address @w@
  -> Signal dom a
  -- ^ Value to write (at address @w@)
  -> Signal dom a
  -- ^ Value of the @blockRAM@ at address @r@ from the previous clock cycle
blockRamU# clk en SNat =
  -- TODO: Generalize to single BRAM primitive taking an initialization function
  blockRam#
    clk
    en
    (CV.map
      (\i -> deepErrorX $ "Initial value at index " <> show i <> " undefined.")
      (iterateI @n succ (0 :: Int)))
{-# NOINLINE blockRamU# #-}
{-# ANN blockRamU# hasBlackBox #-}

-- | Version of blockram that is initialized with the same value on all
-- memory positions.
blockRam1
   :: forall n dom a r addr
   . ( KnownDomain dom
     , HasCallStack
     , NFDataX a
     , Enum addr
     , 1 <= n )
  => Clock dom
  -- ^ 'Clock' to synchronize to
  -> Reset dom
  -- ^ 'Reset' line to listen to. Needs to be held at least /n/ cycles in order
  -- for the BRAM to be reset to its initial state.
  -> Enable dom
  -- ^ Global enable
  -> ResetStrategy r
  -- ^ Whether to clear BRAM on asserted reset ('ClearOnReset') or
  -- not ('NoClearOnReset'). Reset needs to be asserted at least /n/ cycles to
  -- clear the BRAM.
  -> SNat n
  -- ^ Number of elements in BRAM
  -> a
  -- ^ Initial content of the BRAM (replicated /n/ times)
  -> Signal dom addr
  -- ^ Read address @r@
  -> Signal dom (Maybe (addr, a))
  -- ^ (write address @w@, value to write)
  -> Signal dom a
  -- ^ Value of the @blockRAM@ at address @r@ from the previous clock cycle
blockRam1 clk rst0 en rstStrategy n@SNat a rd0 mw0 =
  case rstStrategy of
    ClearOnReset ->
      -- Use reset infrastructure
      blockRam1# clk en n a rd1 we1 wa1 w1
    NoClearOnReset ->
      -- Ignore reset infrastructure, pass values unchanged
      blockRam1# clk en n a
        (fromEnum <$> rd0)
        we0
        (fromEnum <$> wa0)
        w0
 where
  rstBool = register clk rst0 en True (pure False)
  rstInv = invertReset rst0

  waCounter :: Signal dom (Index n)
  waCounter = register clk rstInv en 0 (satSucc SatBound <$> waCounter)

  wa0 = fst . fromJustX <$> mw0
  w0  = snd . fromJustX <$> mw0
  we0 = isJust <$> mw0

  rd1 = mux rstBool 0 (fromEnum <$> rd0)
  we1 = mux rstBool (pure True) we0
  wa1 = mux rstBool (fromInteger . toInteger <$> waCounter) (fromEnum <$> wa0)
  w1  = mux rstBool (pure a) w0

-- | blockRAM1 primitive
blockRam1#
  :: forall n dom a
   . ( KnownDomain dom
     , HasCallStack
     , NFDataX a )
  => Clock dom
  -- ^ 'Clock' to synchronize to
  -> Enable dom
  -- ^ Global Enable
  -> SNat n
  -- ^ Number of elements in BRAM
  -> a
  -- ^ Initial content of the BRAM (replicated /n/ times)
  -> Signal dom Int
  -- ^ Read address @r@
  -> Signal dom Bool
  -- ^ Write enable
  -> Signal dom Int
  -- ^ Write address @w@
  -> Signal dom a
  -- ^ Value to write (at address @w@)
  -> Signal dom a
  -- ^ Value of the @blockRAM@ at address @r@ from the previous clock cycle
blockRam1# clk en n a =
  -- TODO: Generalize to single BRAM primitive taking an initialization function
  blockRam# clk en (replicate n a)
{-# NOINLINE blockRam1# #-}
{-# ANN blockRam1# hasBlackBox #-}

-- | blockRAM primitive
blockRam#
  :: forall dom a n
   . ( KnownDomain dom
     , HasCallStack
     , NFDataX a )
  => Clock dom
  -- ^ 'Clock' to synchronize to
  -> Enable dom
  -- ^ Global enable
  -> Vec n a
  -- ^ Initial content of the BRAM, also
  -- determines the size, @n@, of the BRAM.
  --
  -- __NB__: __MUST__ be a constant.
  -> Signal dom Int
  -- ^ Read address @r@
  -> Signal dom Bool
  -- ^ Write enable
  -> Signal dom Int
  -- ^ Write address @w@
  -> Signal dom a
  -- ^ Value to write (at address @w@)
  -> Signal dom a
  -- ^ Value of the @blockRAM@ at address @r@ from the previous clock cycle
blockRam# (Clock _) gen content = \rd wen waS wd -> runST $ do
  ramStart <- newListArray (0,szI-1) contentL
  -- start benchmark only
  -- ramStart <- unsafeThawSTArray ramArr
  -- end benchmark only
  go
    ramStart
    (withFrozenCallStack (deepErrorX "blockRam: intial value undefined"))
    (fromEnable gen)
    rd
    (fromEnable gen .&&. wen)
    waS
    wd
 where
  contentL = unsafeCoerce content :: [a]
  szI = L.length contentL
  -- start benchmark only
  -- ramArr = listArray (0,szI-1) contentL
  -- end benchmark only

  go :: STArray s Int a -> a -> Signal dom Bool -> Signal dom Int
     -> Signal dom Bool -> Signal dom Int -> Signal dom a
     -> ST s (Signal dom a)
  go !ram o ret@(~(re :- res)) rt@(~(r :- rs)) et@(~(e :- en)) wt@(~(w :- wr)) dt@(~(d :- din)) = do
    o `seqX` (o :-) <$> (ret `seq` rt `seq` et `seq` wt `seq` dt `seq`
      unsafeInterleaveST
        (do o' <- unsafeIOToST
                    (catch (if re then unsafeSTToIO (ram `safeAt` r) else pure o)
                    (\err@XException {} -> pure (throw err)))
            d `defaultSeqX` upd ram e (fromEnum w) d
            go ram o' res rs en wr din))

  upd :: STArray s Int a -> Bool -> Int -> a -> ST s ()
  upd ram we waddr d = case maybeIsX we of
    Nothing -> case maybeIsX waddr of
      Nothing -> forM_ [0..(szI-1)] (\i -> unsafeWriteSTArray ram i (seq waddr d))
      Just wa -> safeUpdate wa d ram
    Just True -> case maybeIsX waddr of
      Nothing -> forM_ [0..(szI-1)] (\i -> unsafeWriteSTArray ram i (seq waddr d))
      Just wa -> safeUpdate wa d ram
    _ -> return ()

  safeAt :: HasCallStack => STArray s Int a -> Int -> ST s a
  safeAt s i =
    if (0 <= i) && (i < szI) then
      unsafeReadSTArray s i
    else pure $
      withFrozenCallStack
        (deepErrorX ("blockRam: read address " <> show i <>
                     " not in range [0.." <> show szI <> ")"))
  {-# INLINE safeAt #-}

  safeUpdate :: HasCallStack => Int -> a -> STArray s Int a -> ST s ()
  safeUpdate i a s =
    if (0 <= i) && (i < szI) then
      unsafeWriteSTArray s i a
    else
      let d = withFrozenCallStack
                (deepErrorX ("blockRam: write address " <> show i <>
                             " not in range [0.." <> show szI <> ")"))
       in forM_ [0..(szI-1)] (\j -> unsafeWriteSTArray s j d)
  {-# INLINE safeUpdate #-}
{-# ANN blockRam# hasBlackBox #-}
{-# NOINLINE blockRam# #-}

-- | Create read-after-write blockRAM from a read-before-write one
readNew
  :: ( KnownDomain dom
     , NFDataX a
     , Eq addr )
  => Clock dom
  -> Reset dom
  -> Enable dom
  -> (Signal dom addr -> Signal dom (Maybe (addr, a)) -> Signal dom a)
  -- ^ The @ram@ component
  -> Signal dom addr
  -- ^ Read address @r@
  -> Signal dom (Maybe (addr, a))
  -- ^ (Write address @w@, value to write)
  -> Signal dom a
  -- ^ Value of the @ram@ at address @r@ from the previous clock cycle
readNew clk rst en ram rdAddr wrM = mux wasSame wasWritten $ ram rdAddr wrM
  where readNewT rd (Just (wr, wrdata)) = (wr == rd, wrdata)
        readNewT _  Nothing             = (False   , undefined)

        (wasSame,wasWritten) =
          unbundle (register clk rst en (False, undefined)
                             (readNewT <$> rdAddr <*> wrM))

data TDPConfig = TDPConfig {
  writeModeA :: WriteMode,
  writeModeB :: WriteMode,
  outputRegA :: Bool,
  outputRegB :: Bool}

tdpDefault = TDPConfig {
  writeModeA = NoChange,
  writeModeB = NoChange,
  outputRegA = True,
  outputRegB = False}

data RamOp n a = RamRead (Index n) |
                 RamWrite (Index n) a |
                 NoOp
                 deriving(Generic,NFDataX)

ramOpAddr ::(KnownNat n) =>  RamOp n a -> Index n
ramOpAddr (RamRead addr)    = addr
ramOpAddr (RamWrite addr _) = addr
ramOpAddr NoOp              = deepErrorX "Address for No operation undefined"

isRamWrite :: RamOp n a -> Bool
isRamWrite (RamWrite {}) = True
isRamWrite _             = False

ramOpWriteVal :: RamOp n a -> Maybe a
ramOpWriteVal (RamWrite _ val) = Just val
ramOpWriteVal _                = Nothing

isOp :: RamOp n a -> Bool
isOp NoOp = False
isOp _    = True

data WriteMode = WriteFirst | ReadFirst | NoChange deriving(Eq)

-- | Produces vendor-agnostic HDL that will be inferred as a true, dual port
-- block ram. Any values that's being written on a particular port is also the
-- value that will be read on that port, i.e. the same-port read/write behavior
-- is: WriteFirst. For mixed port read/write, when both ports have the same
-- address, when there is a write on the port A, the output of port B is
-- undefined, and visa versa. Implicitly clocked version is
-- `Clash.Prelude.BlockRam.trueDualPortBlockRam`
trueDualPortBlockRam ::
  forall nAddrs domA domB a .
  ( HasCallStack
  , KnownNat nAddrs
  , KnownDomain domA
  , KnownDomain domB
  , NFDataX a
  )
  => Clock domA
  -- ^ Clock for port A
  -> Clock domB
  -- ^ Clock for port B
  -> TDPConfig
  -- ^ Configuration of the TDP Blockram
  -> Signal domA (RamOp nAddrs a)
  -- ^ ram operation for port A
  -> Signal domB (RamOp nAddrs a)
  -- ^ ram operation for port B
  -> (Signal domA a, Signal domB a)
  -- ^ Outputs data on /next/ cycle. When writing, the data written
  -- will be echoed. When reading, the read data is returned.

{-# INLINE trueDualPortBlockRam #-}
trueDualPortBlockRam = \clkA clkB config opA opB ->
  trueDualPortBlockRamWrapper
    (writeModeA config)
    (outputRegA config)
    (writeModeB config)
    (outputRegB config)
    clkA
    (isOp <$> opA)
    (isRamWrite <$> opA)
    (ramOpAddr <$> opA)
    (fromJustX . ramOpWriteVal <$> opA)
    clkB
    (isOp <$> opB)
    (isRamWrite <$> opB)
    (ramOpAddr <$> opB)
    (fromJustX . ramOpWriteVal <$> opB)

trueDualPortBlockRamWrapper wmA outRegA wmB outRegB clkA enA weA addrA datA clkB enB weB addrB datB =
 trueDualPortBlockRam# wmA outRegA wmB outRegB clkA enA weA addrA datA clkB enB weB addrB datB
{-# NOINLINE trueDualPortBlockRamWrapper #-}

-- | Primitive of 'trueDualPortBlockRam'.
trueDualPortBlockRam#, trueDualPortBlockRamWrapper ::
  forall nAddrs domA domB a .
  ( HasCallStack
  , KnownNat nAddrs
  , KnownDomain domA
  , KnownDomain domB
  , NFDataX a
  , (a ~ a)   -- BitPack a -- temp hack to avoid renumbering ~ARGs
  )
  => WriteMode
  -- ^ Write mode for port B
  -> Bool
  -- ^ Whether output B is registered
  -> WriteMode
  -- ^ Write mode for port A
  -> Bool
  -- ^ Whether output A is registered
  -> Clock domA
  -- ^ Clock for port A
  -> Signal domA Bool
  -- ^ Enable for port A
  -> Signal domA Bool
  -- ^ Write enable for port A
  -> Signal domA (Index nAddrs)
  -- ^ Address to read from or write to on port A
  -> Signal domA a
  -- ^ Data in for port A; ignored when /write enable/ is @False@
  -> Clock domB
  -- ^ Clock for port B
  -> Signal domB Bool
  -- ^ Enable for port B
  -> Signal domB Bool
  -- ^ Write enable for port B
  -> Signal domB (Index nAddrs)
  -- ^ Address to read from or write to on port B
  -> Signal domB a
  -- ^ Data in for port B; ignored when /write enable/ is @False@

  -> (Signal domA a, Signal domB a)
  -- ^ Outputs data on /next/ cycle. If write enable is @True@, the data written
  -- will be echoed. If write enable is @False@, the read data is returned.
trueDualPortBlockRam# wmA outRegA wmB outRegB clkA enA weA addrA datA
 clkB enB weB addrB datB
  | snatToNum @Int (clockPeriod @domA) < snatToNum @Int (clockPeriod @domB)
  = swap (trueDualPortBlockRamModel
   clkB wmB outRegB enB weB addrB datB clkA wmA outRegA enA weA addrA datA)
  | otherwise
  = trueDualPortBlockRamModel
   clkA wmA outRegA enA weA addrA datA clkB wmB outRegB enB weB addrB datB
{-# NOINLINE trueDualPortBlockRam# #-}
{-# ANN trueDualPortBlockRam# hasBlackBox #-}


-- | Haskell model for the primitive 'trueDualPortBlockRam#'.
--
-- Warning: this model only works if @domFast@'s clock is faster (or equal to)
-- @domSlow@'s clock.
trueDualPortBlockRamModel ::
  forall nAddrs domFast domSlow a .
  ( HasCallStack
  , KnownNat nAddrs
  , KnownDomain domSlow
  , KnownDomain domFast
  , NFDataX a
  ) =>

  Clock domSlow ->
  WriteMode ->
  Bool ->
  Signal domSlow Bool ->
  Signal domSlow Bool ->
  Signal domSlow (Index nAddrs) ->
  Signal domSlow a ->

  Clock domFast ->
  WriteMode ->
  Bool ->
  Signal domFast Bool ->
  Signal domFast Bool ->
  Signal domFast (Index nAddrs) ->
  Signal domFast a ->

  (Signal domSlow a, Signal domFast a)
trueDualPortBlockRamModel !_clkSlow wmSlow outRegSlow enSlow weSlow addrSlow datSlow
                          !_clkFast wmFast outRegFast enFast weFast addrFast datFast
                          = (initSlow :- outSlow, initFast :- outFast)
 where
  initSlow = deepErrorX "trueDualPortBlockRam: Port Slow: First value undefined"
  initFast = deepErrorX "trueDualPortBlockRam: Port Fast: First value undefined"

  (outSlow, outFast) =
    go
      (Seq.fromFunction (natToNum @nAddrs) initElement)
      0 -- ensure 'go' hits fast clock first
      (bundle (enSlow, weSlow, fromIntegral <$> addrSlow, datSlow))
      (bundle (enFast, weFast, fromIntegral <$> addrFast, datFast))
      Nothing
      Nothing
      (initSlow, initSlow, initFast, initFast)

  tSlow = snatToNum @Int (clockPeriod @domSlow)
  tFast = snatToNum @Int (clockPeriod @domFast)

  initElement :: Int -> a
  initElement n =
    deepErrorX ("Unknown initial element; position " <> show n)

  getConflict :: Bool -> Int -> Bool -> Int -> Maybe Int -> (Bool, Bool)
  getConflict writeEnable addr otherWriteEnable otherAddr otherWrote =
    (memoryConflict, outputConflict)
    where
      -- A write conflict occurs when the port tries to write to an address while the
      -- other port is in its current cycle writing to the same address. address collides
      writeCycleCollission =
        case (isX addr, isX otherWrote) of
          (Right addr_, Right (Just otherAddr')) -> addr_ == otherAddr'
          (Left _, _) -> True
          (_, Left _) -> True
          (_, Right (Nothing)) -> False

      memoryConflict =
        case isX writeEnable of
          Right False -> False
          _           -> writeCycleCollission
      -- A read conflict occurs when the other port is writing to the same address.
      outputConflict = (sameAddr && otherWriteEnable) || writeCycleCollission
      sameAddr =
        case (isX addr, isX otherAddr) of
          (Left _, _) -> True
          (_, Left _) -> True
          _           -> addr == otherAddr

  unknownEnableAndAddr :: Int -> a
  unknownEnableAndAddr n =
    deepErrorX ("Write enable and data unknown; position " <> show n)

  unknownAddr :: Int -> a
  unknownAddr n =
    deepErrorX ("Write enabled, but address unknown; position " <> show n)

  writeRam :: Bool -> Int -> a -> Seq a -> (Maybe a, Seq a)
  writeRam enable addr dat mem
    | enableUndefined && addrUndefined
    = ( Just (deepErrorX "Unknown enable and address")
      , Seq.fromFunction (natToNum @nAddrs) unknownEnableAndAddr )
    | enable && addrUndefined
    = ( Just (deepErrorX "Unknown address")
      , Seq.fromFunction (natToNum @nAddrs) unknownAddr )
    | enableUndefined
    = writeRam True addr (deepErrorX ("Write unknown; position" <> show addr)) mem
    | enable
    = (Just dat, Seq.update addr dat mem)
    | otherwise
    = (Nothing, mem)
   where
    enableUndefined = isLeft (isX enable)
    addrUndefined = isLeft (isX addr)

  go ::
    Seq a ->
    Int ->
    Signal domSlow (Bool, Bool, Int, a) ->
    Signal domFast (Bool, Bool, Int, a) ->
    Maybe Int ->
    Maybe Int ->
    (a, a, a, a) ->
    (Signal domSlow a, Signal domFast a)
  go ram0 relativeTime as0 bs0 writingSlow writingFast (oldSlow, oldSlow', oldFast, oldFast')=
    if relativeTime <= tFast then goSlow else goFast
   where
    (enSlow_, weSlow_, addrSlow_, datSlow_) :- as1 = as0
    (enFast_, weFast_, addrFast_, datFast_) :- bs1 = bs0

    -- 1 iteration here, as this is the slow clock.
    goSlow = out3 `seqX` (out3 :- as2, bs2)
     where
      (memConflict, outConflict) = getConflict weSlow_ addrSlow_ weFast_ addrFast_ writingFast
      newMem =
        if memConflict
        then deepErrorX
        ("trueDualPortBlockRam Slow port: Memory write conflict, at " <> show addrSlow_)
        else datSlow_

      (wrote, !ram1) = writeRam weSlow_ addrSlow_ newMem ram0

      out0 = case (outConflict, wmSlow) of
        (False, WriteFirst) -> fromMaybe (ram1 `Seq.index` addrSlow_) wrote
        (False, ReadFirst)  -> ram0 `Seq.index` addrSlow_
        (False, NoChange)   -> if weSlow_ then oldSlow else ram0 `Seq.index` addrSlow_
        (True, _)           -> deepErrorX $
         "trueDualPortBlockRam Slow port: Read conflict" <> show addrSlow_

      writing = if weSlow_ then (Just addrSlow_) else Nothing
      out1 = if enSlow_ then out0 else oldSlow
      out2 = if enSlow_ then oldSlow else oldSlow'
      out3 = if outRegSlow then out2 else out1

      (as2, bs2) = go ram1 (relativeTime + tSlow) as1 bs0 writing writingFast
       (out1, out2, oldFast, oldFast')

    -- 1 or more iterations here, as this is the fast clock. First iteration
    -- happens here.
    goFast = out3 `seqX` (as2, out3 :- bs2)
     where
      (memConflict, outConflict) = getConflict weFast_ addrFast_ weSlow_ addrSlow_ writingSlow
      newMem = if memConflict
        then deepErrorX
        ("trueDualPortBlockRam Fast port: Memory write conflict, at " <> show addrFast_)
        else datFast_

      (wrote, !ram1) = writeRam weFast_ addrFast_ newMem ram0

      out0 = case (outConflict, wmFast) of
        (False, WriteFirst) -> fromMaybe (ram1 `Seq.index` addrFast_) wrote
        (False, ReadFirst)  -> ram0 `Seq.index` addrFast_
        (False, NoChange)   -> if weFast_ then oldFast else ram0 `Seq.index` addrFast_
        (True, _)           -> deepErrorX $
         "trueDualPortBlockRam Fast port: Read conflict, at " <> show addrFast_

      writing = if weFast_ then (Just addrFast_) else Nothing
      out1 = if enFast_ then out0 else oldFast
      out2 = if enFast_ then oldFast else oldFast'
      out3 = if outRegFast then out2 else out1

      (as2, bs2) = go ram1 (relativeTime - tFast) as0 bs1 writingSlow writing
       (oldSlow, oldSlow', out1, out2)
