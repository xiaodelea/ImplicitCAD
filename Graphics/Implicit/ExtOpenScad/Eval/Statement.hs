-- Implicit CAD. Copyright (C) 2011, Christopher Olah (chris@colah.ca)
-- Copyright 2014 2015 2016, Julia Longtin (julial@turinglace.com)
-- Released under the GNU AGPLV3+, see LICENSE

-- FIXME: why is this required?
{-# LANGUAGE ScopedTypeVariables #-}

module Graphics.Implicit.ExtOpenScad.Eval.Statement (runStatementI) where

import Prelude(Maybe(Just, Nothing), Bool(True, False), Either(Left, Right), FilePath, IO, (.), ($), show, putStrLn, concatMap, return, (++), fmap, reverse, fst, readFile)

import Graphics.Implicit.ExtOpenScad.Definitions (
                                                  Statement(Include, (:=), Echo, For, If, NewFunction, NewModule, ModuleCall, Sequence, DoNothing),
                                                  Pattern(Name),
                                                  Expr(LitE),
                                                  OVal(OString, OBool, OList, OModule, OVargsModule),
                                                  VarLookup,
                                                  StatementI(StatementI),
                                                  CompState(CompState),
                                                  LanguageOpts
                                                 )

import Graphics.Implicit.ExtOpenScad.Util.OVal (getErrors)
import Graphics.Implicit.ExtOpenScad.Util.ArgParser (argument, defaultTo, argMap)
import Graphics.Implicit.ExtOpenScad.Util.StateC (StateC, errorC, modifyVarLookup, mapMaybeM, lookupVar, pushVals, getRelPath, withPathShiftedBy, getVals, putVals, languageOptions)
import Graphics.Implicit.ExtOpenScad.Eval.Expr (evalExpr, matchPat)
import Graphics.Implicit.ExtOpenScad.Parser.Statement (parseProgram)

import Data.Maybe(fromMaybe)

import Data.Map (union, fromList)

import Control.Monad (forM_, forM, mapM_)

import Control.Monad.State (get, liftIO, mapM, runStateT, (>>))

import System.FilePath (takeDirectory)

-- Run statements out of the OpenScad file.
runStatementI :: StatementI -> StateC ()

runStatementI (StatementI sourcePos (pat := expr)) = do
    val <- evalExpr expr
    let posMatch = matchPat pat val
    case (getErrors val, posMatch) of
        (Just err,  _ ) -> errorC sourcePos err
        (_, Just match) -> modifyVarLookup $ union match
        (_,   Nothing ) -> errorC sourcePos "pattern match failed in assignment"

runStatementI (StatementI sourcePos (Echo exprs)) = do
    let
        show2 (OString s) = s
        show2 x = show x
    vals <- mapM evalExpr exprs
    case getErrors (OList vals) of
        Nothing  -> liftIO . putStrLn $ concatMap show2 vals
        Just err -> errorC sourcePos err

runStatementI (StatementI sourcePos (For pat expr loopContent)) = do
    val <- evalExpr expr
    case (getErrors val, val) of
        (Just err, _)      -> errorC sourcePos err
        (_, OList vals) -> forM_ vals $ \v ->
            case matchPat pat v of
                Just match -> do
                    modifyVarLookup $ union match
                    runSuite loopContent
                Nothing -> return ()
        _ -> return ()

runStatementI (StatementI sourcePos (If expr a b)) = do
    val <- evalExpr expr
    case (getErrors val, val) of
        (Just err,  _  )  -> errorC sourcePos ("In conditional expression of if statement: " ++ err)
        (_, OBool True )  -> runSuite a
        (_, OBool False)  -> runSuite b
        _                 -> return ()

runStatementI (StatementI sourcePos (NewModule name argTemplate suite)) = do
    opts <- languageOptions
    argTemplate' <- forM argTemplate $ \(name', defexpr) -> do
        defval <- mapMaybeM evalExpr defexpr
        return (name', defval)
    (CompState (varlookup, _, path, langOpts, _)) <- get
--  FIXME: \_? really?
    runStatementI . StatementI sourcePos $ (Name name :=) $ LitE $ OModule $ \_ -> do
        newNameVals <- forM argTemplate' $ \(name', maybeDef) -> do
            val <- case maybeDef of
                Just def -> argument name' `defaultTo` def
                Nothing  -> argument name'
            return (name', val)
        let
{-
            children = ONum $ fromIntegral $ length vals
            child = OModule $ \vals -> do
                n :: ℕ <- argument "n";
                return $ return $ return $
                    if n <= length vals
                        then vals !! n
                        else OUndefined
            childBox = OFunc $ \n -> case fromOObj n :: Maybe ℕ of
                Just n  | n < length vals -> case vals !! n of
                    -- _ -> toOObj $ getBox3 obj3
                    -- _ -> toOObj $ getBox2 obj2
                    _ -> OUndefined
                _ -> OUndefined
            newNameVals' = newNameVals ++ [("children", children),("child", child), ("childBox", childBox)]
-}
            varlookup' = union (fromList newNameVals) varlookup
            suiteVals  = runSuiteCapture varlookup' path langOpts suite
        return suiteVals

runStatementI (StatementI sourcePos (ModuleCall name argsExpr suite)) = do
        opts <- languageOptions
        maybeMod  <- lookupVar name
        (CompState (varlookup, _, path, _, _)) <- get
        argsVal   <- forM argsExpr $ \(posName, expr) -> do
            val <- evalExpr expr
            return (posName, val)
        newVals <- case maybeMod of
            Just (OModule mod') -> do
                childVals <- fmap reverse $ liftIO $ runSuiteCapture varlookup path opts suite
                let
                    argparser = mod' childVals
                    ioNewVals = case fst $ argMap argsVal argparser of
                        Just iovals -> iovals
                        Nothing     -> return []
                liftIO ioNewVals
            Just (OVargsModule mod') -> do
                _ <- mod' sourcePos argsVal suite runSuite -- no values are returned
                return []
            Just foo            -> do
                    case getErrors foo of
                        Just err -> errorC sourcePos err
                        Nothing  -> errorC sourcePos "Object called not module!"
                    return []
            Nothing -> do
                errorC sourcePos $ "Module " ++ name ++ " not in scope."
                return []
        pushVals newVals

runStatementI (StatementI _ (Include name injectVals)) = do
    name' <- getRelPath name
    content <- liftIO $ readFile name'
    case parseProgram name' content of
        Left e -> liftIO $ putStrLn $ "Error parsing " ++ name ++ ":" ++ show e
        Right sts -> withPathShiftedBy (takeDirectory name) $ do
            vals <- getVals
            putVals []
            runSuite sts
            vals' <- getVals
            if injectVals then putVals (vals' ++ vals) else putVals vals

runStatementI (StatementI _ (Sequence suite)) =
    runSuite suite

runStatementI (StatementI _ (NewFunction _ _ _)) =
    return ()

runStatementI (StatementI _ DoNothing) =
    return ()

runSuite :: [StatementI] -> StateC ()
runSuite = mapM_ runStatementI

runSuiteCapture :: VarLookup -> FilePath -> LanguageOpts -> [StatementI] -> IO [OVal]
runSuiteCapture varlookup path opts suite = do
    (res, _) <- runStateT
        (runSuite suite >> getVals)
        (CompState (varlookup, [], path, opts, []))
    return res

runSuiteInModule :: FilePath -> LanguageOpts -> [StatementI] -> VarLookup -> IO [OVal]
runSuiteInModule path opts suite varlookup = runSuiteCapture varlookup path opts suite
